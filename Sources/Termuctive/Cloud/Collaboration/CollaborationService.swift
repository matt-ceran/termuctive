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

struct BoardTask: Decodable, Equatable, Identifiable {
    let id: String
    let kind: String
    let from: String
    let to: String
    let title: String
    let details: String?
    let status: String
    let assignee: String?
    let result: String?
    let createdAt: Double

    var isOpen: Bool {
        ["proposed", "queued", "delivered", "started"].contains(status)
    }
}

private struct AutoRunState: Decodable {
    let autoRun: Bool
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
            if Self.serverIsUnreachable(redemption) {
                throw InviteCodeError.serverUnreachable(server: code.serverName, owner: code.owner)
            }
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
            cloud.queueInitialCommand(
                Self.joinSetupCommand(user: code.user, gitIdentity: await GitIdentity.local()),
                forPaneID: paneID
            )
        }
        return projectID
    }

    /// The joined project's first terminal installs Claude Code, gives git the name and
    /// email used on this Mac, signs in to GitHub, then starts Claude Code, which asks the
    /// collaborator to sign in with their own account.
    static func joinSetupCommand(user: String, gitIdentity: GitIdentity?) -> String {
        let tmc = TMCClient.executable
        var steps = [
            "sudo -n \(tmc) admin install-claude --user \(ShellQuoting.quote(user))",
            "\(tmc) claude install-hooks >/dev/null",
            #"export PATH="$HOME/.local/bin:$PATH""#,
        ]
        if let gitIdentity {
            for (key, value) in [
                ("user.name", gitIdentity.name), ("user.email", gitIdentity.email),
            ] {
                steps.append(
                    "git config --global \(key) >/dev/null || "
                        + "git config --global \(key) \(ShellQuoting.quote(value))"
                )
            }
        }
        steps += [
            "gh auth status >/dev/null 2>&1 || { echo; "
                + "echo 'Sign in to GitHub so git can push. Press Return at each question, "
                + "then open the link and type the code.'; "
                + "BROWSER=echo gh auth login --hostname github.com --git-protocol https --web "
                + "&& gh auth setup-git; }",
            "echo",
            "echo 'Starting Claude Code. Sign in with your own Claude account.'",
            "claude",
        ]
        return steps.joined(separator: "; ")
    }

    /// Whether ssh never reached the server, as when this Mac is not on Tailscale yet.
    static func serverIsUnreachable(_ result: ProcessResult) -> Bool {
        guard result.status == 255, !result.timedOut else {
            return false
        }
        let reasons = [
            "Could not resolve hostname", "timed out", "No route to host",
            "Network is unreachable", "Connection refused",
        ]
        return reasons.contains { result.errorText.localizedCaseInsensitiveContains($0) }
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

    func tasks(projectID: UUID) async throws -> [BoardTask] {
        try await run(projectID, [TMCClient.executable, "task", "list"], as: [BoardTask].self)
    }

    func postTask(projectID: UUID, to member: String, title: String, details: String) async throws {
        _ = try await run(
            projectID,
            [
                TMCClient.executable, "task", "post", "--to", member, "--title", title,
                "--details", details,
            ],
            as: BoardTask.self
        )
    }

    func autoRun(projectID: UUID) async throws -> Bool {
        try await run(
            projectID, [TMCClient.executable, "autorun", "status"], as: AutoRunState.self
        )
        .autoRun
    }

    func setAutoRun(_ enabled: Bool, projectID: UUID) async throws {
        _ = try await run(
            projectID,
            [TMCClient.executable, "autorun", enabled ? "on" : "off"],
            as: AutoRunState.self
        )
    }

    /// Runs a toolkit command for the project's slug, which is appended as `--slug`.
    private func run<Value: Decodable>(
        _ projectID: UUID,
        _ arguments: [String],
        as type: Value.Type
    ) async throws -> Value {
        guard let binding = cloud.cloudStore.binding(forProjectID: projectID),
            let host = cloud.cloudStore.host(withID: binding.hostID)
        else {
            throw CloudCommandError.invalidResponse("This project is not in the cloud.")
        }
        await cloud.control.ensureMaster(alias: host.alias)
        return try await cloud.runner.decode(
            type,
            CloudCommand(
                alias: host.alias, remote: .arguments(arguments + ["--slug", binding.slug]))
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

/// The git author this Mac uses, so a collaborator's commits on the server carry it too.
struct GitIdentity: Equatable {
    var name: String
    var email: String

    static func local() async -> GitIdentity? {
        // Without developer tools, /usr/bin/git asks to install them instead of answering.
        guard (try? await ProcessRunner.run("/usr/bin/xcode-select", ["-p"]))?.succeeded == true,
            let name = await value("user.name"),
            let email = await value("user.email")
        else {
            return nil
        }
        return GitIdentity(name: name, email: email)
    }

    private static func value(_ key: String) async -> String? {
        guard
            let result = try? await ProcessRunner.run(
                "/usr/bin/git", ["config", "--global", "--get", key]),
            result.succeeded
        else {
            return nil
        }
        let value = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
