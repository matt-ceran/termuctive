import Foundation

struct InviteResponse: Decodable, Equatable {
    let inviteID: String
    let user: String
    let home: String
    let expires: String
    let hostKeys: [String]
    let slug: String
    let root: String
    let owner: String
}

struct TeamReport: Decodable, Equatable {
    struct Member: Decodable, Equatable {
        let user: String
        let isYou: Bool
        let sessions: [Session]
    }

    struct Session: Decodable, Equatable {
        let pane: UUID
        let cwd: String?
        let updated: Double?
        let claude: RemoteSessionReport.Claude?
    }

    let slug: String
    let owner: String?
    let members: [Member]
}

/// What a Watch window shows: another member's session, read-only.
struct CloudWatchTarget: Codable, Hashable, Identifiable {
    let configPath: String
    let alias: String
    let slug: String
    let member: String
    let paneID: UUID
    let title: String

    var id: String {
        "\(alias)/\(slug)/\(member)/\(paneID.uuidString)"
    }

    var arguments: [String] {
        [
            "-F", configPath, "-tt", "-o", "BatchMode=yes", "-o", "ControlPath=none", alias, "--",
            ShellQuoting.command([
                TMCClient.executable, "watch", "--slug", slug, "--member", member,
                "--pane", paneID.uuidString.lowercased(),
            ]),
        ]
    }
}

/// Invites collaborators to cloud projects and joins projects from invite codes.
@MainActor
struct CollaborationService {
    let cloud: CloudSessionCoordinator
    let store: WorkspaceStore

    /// Creates the collaborator's account and a one-time invite. Large projects take a
    /// few minutes because every file is shared with the project group.
    func invite(projectID: UUID, partner: String, partnerHome: String) async throws -> InviteCode {
        guard let binding = cloud.cloudStore.binding(forProjectID: projectID),
            let host = cloud.cloudStore.host(withID: binding.hostID),
            let project = store.document.projects.first(where: { $0.id == projectID })
        else {
            throw CloudCommandError.invalidResponse("This project is not in the cloud.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termuctive-invite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let keyURL = directory.appendingPathComponent("invite")
        let publicKey = try await SSHKeyManager.ensureKey(at: keyURL, comment: "termuctive-invite")
        let privateKey = try String(contentsOf: keyURL, encoding: .utf8)

        var arguments = [
            "sudo", "-n", TMCClient.executable, "admin", "invite",
            "--slug", binding.slug, "--name", partner, "--home", partnerHome,
            "--invite-key", publicKey,
        ]
        for path in binding.sharedPaths {
            arguments += ["--share-path", path]
        }
        await cloud.control.ensureMaster(alias: host.alias)
        let response = try await cloud.runner.decode(
            InviteResponse.self,
            CloudCommand(alias: host.alias, remote: .arguments(arguments), timeout: 3_600)
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expires =
            formatter.date(from: response.expires)
            ?? ISO8601DateFormatter().date(from: response.expires)
            ?? Date().addingTimeInterval(48 * 60 * 60)
        return InviteCode(
            serverName: host.name,
            address: host.tailscaleName ?? host.address,
            port: host.port,
            user: response.user,
            home: response.home,
            hostKeys: response.hostKeys,
            slug: response.slug,
            root: response.root,
            projectName: project.name.replacingOccurrences(of: " (Cloud)", with: ""),
            owner: response.owner,
            inviteID: response.inviteID,
            privateKey: privateKey,
            expires: expires
        )
    }

    /// Redeems an invite on the collaborator's Mac and adds the cloud project to the sidebar.
    func join(_ code: InviteCode) async throws -> UUID {
        guard !code.isExpired() else {
            throw InviteCodeError.expired
        }
        let paths = cloud.paths
        try paths.prepareDirectories()
        let memberKey = try await SSHKeyManager.ensureKey(
            at: paths.memberKeyURL,
            comment: SSHKeyManager.comment(for: "member")
        )
        let host = CloudHost(
            name: code.serverName,
            address: code.address,
            port: code.port,
            adminUser: "",
            memberUser: code.user,
            tailscaleName: code.address.hasSuffix(".ts.net") ? code.address : nil
        )
        try Self.pin(hostKeys: code.hostKeys, alias: host.alias, knownHosts: paths.knownHostsURL)
        cloud.cloudStore.addOrUpdate(host)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termuctive-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let inviteKey = directory.appendingPathComponent("invite")
        try code.privateKey.write(to: inviteKey, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: inviteKey.path)

        let redemption = try await ProcessRunner.run(
            "/usr/bin/ssh",
            [
                "-F", paths.configURL.path, "-T", "-o", "BatchMode=yes",
                "-o", "ControlPath=none", "-i", inviteKey.path, host.alias,
            ],
            input: Data((memberKey + "\n").utf8),
            timeout: 60
        )
        guard redemption.succeeded else {
            cloud.cloudStore.removeHost(withID: host.id)
            throw CloudCommandError.failed(
                command: "join",
                status: redemption.status,
                message: redemption.errorText.isEmpty
                    ? "The server did not accept the invite. It may have been used already."
                    : redemption.errorText
            )
        }
        let status = try await cloud.client.status(alias: host.alias)
        var joined = host
        joined.toolkitVersion = status.toolkit.version
        cloud.cloudStore.addOrUpdate(joined)

        let projectID = store.addCloudProject(
            name: "\(code.projectName) (Cloud)",
            rootDirectory: code.root
        )
        cloud.cloudStore.bind(
            CloudProjectBinding(
                projectID: projectID,
                hostID: host.id,
                slug: code.slug,
                remoteRoot: code.root,
                role: .member
            )
        )
        cloud.workspaceTerminalsChanged()
        if let paneID = store.focusedPaneID {
            let tmc = TMCClient.executable
            cloud.queueInitialCommand(
                [
                    "sudo -n \(tmc) admin install-claude --user \(code.user)",
                    "\(tmc) claude install-hooks >/dev/null",
                    "\(tmc) checklist --root \(ShellQuoting.quote(code.root))",
                ].joined(separator: "; "),
                forPaneID: paneID
            )
        }
        return projectID
    }

    func team(projectID: UUID) async throws -> TeamReport {
        guard let binding = cloud.cloudStore.binding(forProjectID: projectID),
            let host = cloud.cloudStore.host(withID: binding.hostID)
        else {
            throw CloudCommandError.invalidResponse("This project is not in the cloud.")
        }
        await cloud.control.ensureMaster(alias: host.alias)
        return try await cloud.runner.decode(
            TeamReport.self,
            CloudCommand(
                alias: host.alias,
                remote: .arguments([TMCClient.executable, "team", "--slug", binding.slug])
            )
        )
    }

    func watchTarget(
        projectID: UUID,
        member: String,
        paneID: UUID,
        title: String
    ) -> CloudWatchTarget? {
        guard let binding = cloud.cloudStore.binding(forProjectID: projectID),
            let host = cloud.cloudStore.host(withID: binding.hostID)
        else {
            return nil
        }
        return CloudWatchTarget(
            configPath: cloud.paths.configURL.path,
            alias: host.alias,
            slug: binding.slug,
            member: member,
            paneID: paneID,
            title: title
        )
    }

    /// Records the server's host keys under the alias every connection uses.
    static func pin(hostKeys: [String], alias: String, knownHosts: URL) throws {
        let existing = (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(alias + " ") }
        lines += hostKeys.map { "\(alias) \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(
            to: knownHosts,
            atomically: true,
            encoding: .utf8
        )
    }
}
