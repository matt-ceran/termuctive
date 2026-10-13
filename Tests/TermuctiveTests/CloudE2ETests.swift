import AppKit
import XCTest

@testable import Termuctive

/// Drives the real cloud stack against a disposable Ubuntu server in Docker.
///
/// Run with TERMUCTIVE_CLOUD_E2E=1. The test starts the server itself through
/// Scripts/cloud-test-server.sh, which needs Docker.
@MainActor
final class CloudE2ETests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testServerSetupAndPersistentCloudTerminal() async throws {
        let (store, cloud, host) = try await prepareServer()
        let projectRoot = NSHomeDirectory() + "/termuctive-e2e project"
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let project = try XCTUnwrap(store.selectedProject)
        let paneID = try XCTUnwrap(store.selectedSpace?.layout.firstTerminalID)
        store.updateTerminal(paneID: paneID, workingDirectory: projectRoot)
        try await cloud.connect(
            projectID: project.id,
            host: host,
            slug: "e2e",
            remoteRoot: projectRoot
        )

        let sessions = TerminalSessionPool(
            store: store,
            launchResolver: { [weak cloud] pane in
                cloud?.launchSpec(for: pane) ?? .localShell
            }
        )
        cloud.attach(sessions: sessions)
        defer {
            sessions.terminateAll()
        }
        let pane = try XCTUnwrap(store.document.terminal(withID: paneID))
        let terminal = sessions.terminalView(for: pane)
        terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 480)

        _ = try await output(of: terminal, containing: "$ ")
        terminal.send(txt: "echo E2E-$((6*7)) \"$PWD\"\r")
        _ = try await output(of: terminal, containing: "E2E-42 \(projectRoot)")

        // Drop the connection the way a sleeping laptop would; the session must survive.
        kill(terminal.process.shellPid, SIGKILL)
        try await waitUntil(timeout: 20) {
            if case .reconnecting = sessions.status(for: paneID) {
                return true
            }
            return false
        }
        try await waitUntil(timeout: 30) { sessions.status(for: paneID) == .running }
        let restored = try await output(of: terminal, containing: "E2E-42")
        XCTAssertTrue(restored.contains("E2E-42"))

        let listed = try await cloud.client.listSessions(alias: host.alias, slug: "e2e")
        XCTAssertEqual(listed.map(\.pane), [paneID])

        // A Claude Code hook running inside the pane reports state the bridge can read.
        terminal.send(
            txt: "echo '{\"session_id\": \"abc-123\", \"prompt\": \"hi\"}' "
                + "| /opt/termuctive/bin/tmc hook prompt && echo HOOKED\r"
        )
        _ = try await output(of: terminal, containing: "HOOKED")
        let reports = try await cloud.runner.decode(
            [RemoteSessionReport].self,
            CloudCommand(
                alias: host.alias,
                remote: .arguments([TMCClient.executable, "sessions", "--slug", "e2e"])
            )
        )
        XCTAssertEqual(reports.map(\.pane), [paneID])
        XCTAssertEqual(reports.first?.claude?.state, "working")
        XCTAssertEqual(reports.first?.claude?.sessionId, "abc-123")

        // Toolkit updates use the administrator's passwordless sudo.
        let toolkit = try XCTUnwrap(
            CloudToolkit.bundled(in: repository.appendingPathComponent("Resources"))
        )
        let installer = CloudToolkitInstaller(runner: cloud.runner, toolkit: toolkit)
        try await installer.upload(toAlias: host.adminAlias)
        try await installer.installUploadedToolkit(adminAlias: host.adminAlias)

        try await cloud.client.killSession(alias: host.alias, slug: "e2e", paneID: paneID)
        let afterKill = try await cloud.client.listSessions(alias: host.alias, slug: "e2e")
        XCTAssertTrue(afterKill.isEmpty)
    }

    func testMovingAProjectCopiesItExactly() async throws {
        let (_, cloud, host) = try await prepareServer()
        let fixture = NSHomeDirectory() + "/.termuctive-e2e/move project"
        let related = NSHomeDirectory() + "/termuctive-e2e-related"
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.termuctive-e2e")
        try? FileManager.default.removeItem(atPath: related)
        defer {
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.termuctive-e2e")
            try? FileManager.default.removeItem(atPath: related)
        }
        try makeFixture(at: fixture, related: related)

        let fakeClaudeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("termuctive-e2e-claude-\(UUID().uuidString)")
        var manifest = try await ProjectScanner(
            claude: ClaudeLocalData(homeDirectory: fakeClaudeHome)
        ).scan(
            projectID: UUID(),
            projectName: "move project",
            root: fixture,
            paneDirectories: []
        )
        // Never copy this Mac's real credentials into a test container.
        for index in manifest.items.indices
        where [.personalFile, .personalFolder, .claudeConfiguration].contains(
            manifest.items[index].kind
        ) {
            manifest.items[index].selected = false
        }
        XCTAssertTrue(
            manifest.items.contains { $0.kind == .relatedFolder && $0.localPath == related })

        let engine = TransferEngine(
            manifest: manifest,
            host: host,
            slug: "move",
            runner: cloud.runner,
            paths: cloud.paths
        )
        let firstPass = await engine.run(.initial)
        XCTAssertTrue(firstPass, "\(engine.state)")

        try "print('changed')\n".write(
            toFile: fixture + "/app.py", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: fixture + "/remove-me.txt")
        try "new\n".write(toFile: fixture + "/added.txt", atomically: true, encoding: .utf8)
        let finalPass = await engine.run(.final)
        XCTAssertTrue(finalPass, "\(engine.state)")

        let worktree = fixture + "/.worktrees/feature"
        let checks = try await remote(
            cloud,
            host,
            [
                "cat \(ShellQuoting.quote(fixture + "/app.py"))",
                "test ! -e \(ShellQuoting.quote(fixture + "/remove-me.txt")) && echo removed",
                "cat \(ShellQuoting.quote(fixture + "/added.txt"))",
                "stat -c %a \(ShellQuoting.quote(fixture + "/.env"))",
                "test ! -e \(ShellQuoting.quote(fixture + "/node_modules")) && echo no-deps",
                "git -C \(ShellQuoting.quote(fixture)) config core.ignorecase",
                "cat \(ShellQuoting.quote(related + "/notes.txt"))",
            ].joined(separator: "; ")
        )
        XCTAssertEqual(
            checks.split(separator: "\n").map(String.init),
            ["print('changed')", "removed", "new", "600", "no-deps", "false", "related data"]
        )

        let localStatus = try await ProcessRunner.run(
            "/usr/bin/git",
            ["-C", worktree, "status", "--porcelain=v1"]
        ).outputText
        let remoteStatus = try await remote(
            cloud,
            host,
            "git -C \(ShellQuoting.quote(worktree)) status --porcelain=v1"
        )
        XCTAssertFalse(localStatus.isEmpty)
        XCTAssertEqual(remoteStatus, localStatus)
        let worktrees = try await remote(
            cloud,
            host,
            "git -C \(ShellQuoting.quote(fixture)) worktree list --porcelain | grep '^worktree '"
        )
        XCTAssertTrue(worktrees.contains("worktree \(worktree)"))
    }

    func testCollaboratorJoinsSharesWatchesAndBringsTheirWork() async throws {
        let (mattStore, mattCloud, host) = try await prepareServer()
        let base = NSHomeDirectory() + "/.termuctive-e2e"
        let fixture = base + "/team project"
        let related = NSHomeDirectory() + "/termuctive-e2e-related"
        try? FileManager.default.removeItem(atPath: base)
        try? FileManager.default.removeItem(atPath: related)
        defer {
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: related)
        }
        try makeFixture(at: fixture, related: related)

        // Matt moves the project and already has a Claude memory for it.
        var manifest = try await ProjectScanner(
            claude: ClaudeLocalData(homeDirectory: URL(fileURLWithPath: base + "/no-claude"))
        ).scan(projectID: UUID(), projectName: "team", root: fixture, paneDirectories: [])
        for index in manifest.items.indices
        where [.personalFile, .personalFolder, .claudeConfiguration].contains(
            manifest.items[index].kind
        ) {
            manifest.items[index].selected = false
        }
        let moved = await TransferEngine(
            manifest: manifest,
            host: host,
            slug: "team",
            runner: mattCloud.runner,
            paths: mattCloud.paths
        ).run(.initial)
        XCTAssertTrue(moved)
        let projectID = mattStore.addCloudProject(name: "team (Cloud)", rootDirectory: fixture)
        mattCloud.cloudStore.bind(
            CloudProjectBinding(
                projectID: projectID,
                hostID: host.id,
                slug: "team",
                remoteRoot: fixture,
                role: .owner,
                sharedPaths: [related]
            )
        )
        let key = ClaudeLocalData.projectKey(for: fixture)
        _ = try await remote(
            mattCloud,
            host,
            "mkdir -p ~/.claude/projects/\(key)/memory && echo owner-memory > "
                + "~/.claude/projects/\(key)/memory/owner.md"
        )

        // Matt invites Sam; Sam joins on his own Mac.
        let invite = try await CollaborationService(cloud: mattCloud, store: mattStore).invite(
            projectID: projectID,
            partner: "sam",
            partnerHome: "/Users/sam"
        )
        XCTAssertFalse(invite.hostKeys.isEmpty)
        let samStore = WorkspaceStore(persistence: E2EWorkspacePersistence())
        let samCloudStore = CloudStore(persistence: InMemoryCloudPersistence())
        let samCloud = CloudSessionCoordinator(
            store: samStore,
            cloudStore: samCloudStore,
            paths: makeTemporarySSHPaths(),
            observesSystemEvents: false
        )
        let samProjectID = try await CollaborationService(cloud: samCloud, store: samStore)
            .join(try InviteCode.decode(try invite.encoded()))
        let samHost = try XCTUnwrap(samCloudStore.hosts.first)
        let samBinding = try XCTUnwrap(samCloudStore.binding(forProjectID: samProjectID))
        XCTAssertEqual(samBinding.role, .member)

        let replayStore = WorkspaceStore(persistence: E2EWorkspacePersistence())
        let replay = CloudSessionCoordinator(
            store: replayStore,
            cloudStore: CloudStore(persistence: InMemoryCloudPersistence()),
            paths: makeTemporarySSHPaths(),
            observesSystemEvents: false
        )
        do {
            _ = try await CollaborationService(cloud: replay, store: replayStore).join(invite)
            XCTFail("An invite must only work once")
        } catch {}

        // Sam shares the project files, .env files, related folders and memories.
        let shared = try await remote(
            samCloud,
            samHost,
            [
                "cat \(ShellQuoting.quote(fixture + "/app.py"))",
                "cat \(ShellQuoting.quote(fixture + "/.env"))",
                "cat \(ShellQuoting.quote(related + "/notes.txt"))",
                "cat ~/.claude/projects/\(key)/memory/owner.md",
                "echo sam-memory > ~/.claude/projects/\(key)/memory/sam.md",
            ].joined(separator: " && ")
        )
        XCTAssertEqual(
            shared.split(separator: "\n").map(String.init),
            ["print('hello')", "SECRET=1", "related data", "owner-memory"]
        )
        let seenByMatt = try await remote(
            mattCloud,
            host,
            "cat ~/.claude/projects/\(key)/memory/sam.md"
        )
        XCTAssertEqual(seenByMatt, "sam-memory\n")

        // Sam watches Matt's live session, read-only.
        let sessions = TerminalSessionPool(
            store: mattStore,
            launchResolver: { [weak mattCloud] pane in
                mattCloud?.launchSpec(for: pane) ?? .localShell
            }
        )
        mattCloud.attach(sessions: sessions)
        defer {
            sessions.terminateAll()
        }
        let pane = try XCTUnwrap(
            mattStore.selectedSpace.flatMap {
                $0.layout.terminal(withID: $0.layout.firstTerminalID)
            }
        )
        let terminal = sessions.terminalView(for: pane)
        terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        _ = try await output(of: terminal, containing: "$ ")
        terminal.send(txt: "echo WATCH-ME-$((2*21))\r")
        _ = try await output(of: terminal, containing: "WATCH-ME-42")

        let target = try XCTUnwrap(
            CollaborationService(cloud: samCloud, store: samStore).watchTarget(
                projectID: samProjectID,
                member: host.memberUser,
                paneID: pane.id,
                title: "Matt"
            )
        )
        let watcher = TermuctiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        watcher.startProcess(
            executable: "/usr/bin/ssh",
            args: target.arguments,
            environment: TerminalShellConfiguration.live.environment,
            execName: nil,
            currentDirectory: NSHomeDirectory()
        )
        _ = try await output(of: watcher, containing: "WATCH-ME-42")
        watcher.send(txt: "echo TYPED-BY-WATCHER\r")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let mattScreen = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertFalse(mattScreen.contains("TYPED-BY-WATCHER"))
        watcher.terminate()

        let team = try await CollaborationService(cloud: samCloud, store: samStore).team(
            projectID: samProjectID
        )
        XCTAssertEqual(Set(team.members.map(\.user)), [host.memberUser, "sam"])
        XCTAssertTrue(
            team.members.first { $0.user == host.memberUser }?.sessions.contains {
                $0.pane == pane.id
            }
                ?? false
        )

        // Sam brings his own local copy of the project.
        let samLocal = base + "/sam copy"
        XCTAssertEqual(try ProcessRunnerSync.git(["clone", "-q", fixture, samLocal]), 0)
        for arguments in [
            ["config", "user.email", "sam@example.com"], ["config", "user.name", "Sam"],
            ["checkout", "-q", "-b", "sam-feature"],
        ] {
            XCTAssertEqual(try ProcessRunnerSync.git(["-C", samLocal] + arguments), 0)
        }
        try "print('sam committed')\n".write(
            toFile: samLocal + "/sam.py",
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(try ProcessRunnerSync.git(["-C", samLocal, "add", "sam.py"]), 0)
        XCTAssertEqual(
            try ProcessRunnerSync.git(["-C", samLocal, "commit", "-q", "-m", "sam"]),
            0
        )
        try "print('sam in progress')\n".write(
            toFile: samLocal + "/app.py",
            atomically: true,
            encoding: .utf8
        )
        try "SECRET=sam\n".write(toFile: samLocal + "/.env", atomically: true, encoding: .utf8)
        let samClaude = ClaudeLocalData(homeDirectory: URL(fileURLWithPath: base + "/sam-home"))
        let history = samClaude.projectsDirectory
            .appendingPathComponent(ClaudeLocalData.projectKey(for: samLocal))
        try FileManager.default.createDirectory(
            at: history.appendingPathComponent("memory"),
            withIntermediateDirectories: true
        )
        try "sam's own memory\n".write(
            to: history.appendingPathComponent("memory/from-sams-mac.md"),
            atomically: true,
            encoding: .utf8
        )
        try "{\"cwd\": \"\(samLocal)\"}\n".write(
            to: history.appendingPathComponent("a.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let importer = PartnerImport(
            localRoot: samLocal,
            binding: samBinding,
            host: samHost,
            cloud: samCloud,
            claude: samClaude
        )
        importer.includesSettings = false
        await importer.run()
        XCTAssertEqual(importer.state, .finished, "\(importer.notes)")

        let worktree = fixture + "/.worktrees/sam-sam-feature"
        XCTAssertEqual(importer.createdWorktrees, [worktree])
        let imported = try await remote(
            samCloud,
            samHost,
            [
                "cat \(ShellQuoting.quote(worktree + "/app.py"))",
                "cat \(ShellQuoting.quote(worktree + "/sam.py"))",
                "cat \(ShellQuoting.quote(worktree + "/.env"))",
                "git -C \(ShellQuoting.quote(worktree)) rev-parse --abbrev-ref HEAD",
                "cat ~/.claude/projects/\(key)/memory/from-sams-mac.md",
                "test -e ~/.claude/projects/\(key)/a.jsonl && echo history",
            ].joined(separator: " && ")
        )
        XCTAssertEqual(
            imported.split(separator: "\n").map(String.init),
            [
                "print('sam in progress')", "print('sam committed')", "SECRET=sam",
                "sam-feature", "sam's own memory", "history",
            ]
        )
    }

    private func remote(
        _ cloud: CloudSessionCoordinator,
        _ host: CloudHost,
        _ script: String
    ) async throws -> String {
        try await cloud.runner.output(
            CloudCommand(alias: host.alias, remote: .script(script), timeout: 60)
        ).outputText
    }

    private func makeFixture(at root: String, related: String) throws {
        let files: [String: String] = [
            ".gitignore": "node_modules/\n.env\n.worktrees/\n",
            "app.py": "print('hello')\n",
            "remove-me.txt": "bye\n",
            "CLAUDE.md": "Training data lives in ~/termuctive-e2e-related.\n",
            ".env": "SECRET=1\n",
            "node_modules/pkg/index.js": "module.exports = 1\n",
        ]
        for (path, contents) in files {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: related, withIntermediateDirectories: true)
        try "related data\n".write(
            toFile: related + "/notes.txt", atomically: true, encoding: .utf8)
        for arguments in [
            ["init", "-q"], ["config", "user.email", "e2e@example.com"],
            ["config", "user.name", "E2E"],
            ["add", "."], ["commit", "-q", "-m", "start"],
            ["worktree", "add", "-q", "-b", "feature", ".worktrees/feature"],
        ] {
            let result = try ProcessRunnerSync.git(["-C", root] + arguments)
            XCTAssertEqual(result, 0, "git \(arguments.joined(separator: " "))")
        }
        try "print('work in progress')\n".write(
            toFile: root + "/.worktrees/feature/app.py",
            atomically: true,
            encoding: .utf8
        )
        try "scratch\n".write(
            toFile: root + "/.worktrees/feature/notes.txt",
            atomically: true,
            encoding: .utf8
        )
    }

    private func prepareServer() async throws -> (
        WorkspaceStore, CloudSessionCoordinator, CloudHost
    ) {
        guard ProcessInfo.processInfo.environment["TERMUCTIVE_CLOUD_E2E"] == "1" else {
            throw XCTSkip("Set TERMUCTIVE_CLOUD_E2E=1 to run against a Docker test server.")
        }
        let paths = makeTemporarySSHPaths()
        try paths.prepareDirectories()
        let memberKey = try await SSHKeyManager.ensureKey(
            at: paths.memberKeyURL,
            comment: "termuctive-member-e2e"
        )
        _ = try await SSHKeyManager.ensureKey(
            at: paths.adminKeyURL, comment: "termuctive-admin-e2e")

        let server = try await ProcessRunner.run(
            "/bin/zsh",
            [
                repository.appendingPathComponent("Scripts/cloud-test-server.sh").path,
                "reset",
                paths.adminKeyURL.appendingPathExtension("pub").path,
            ],
            timeout: 600
        )
        XCTAssertTrue(server.succeeded, server.errorText)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let store = WorkspaceStore(persistence: E2EWorkspacePersistence())
        let cloudStore = CloudStore(persistence: InMemoryCloudPersistence())
        let cloud = CloudSessionCoordinator(
            store: store,
            cloudStore: cloudStore,
            paths: paths,
            observesSystemEvents: false
        )
        let memberUser = CloudServerSetupSheet.defaultMemberUser
        let host = CloudHost(
            name: "Docker Test Server",
            address: "127.0.0.1",
            port: 2222,
            adminUser: "admin",
            memberUser: memberUser
        )
        cloudStore.addOrUpdate(host)

        let probe = try await cloud.runner.run(
            CloudCommand(
                alias: host.adminAlias,
                remote: .script("true"),
                options: ["-o", "StrictHostKeyChecking=accept-new"]
            )
        )
        XCTAssertTrue(probe.succeeded, probe.errorText)

        let toolkit = try XCTUnwrap(
            CloudToolkit.bundled(in: repository.appendingPathComponent("Resources"))
        )
        try await CloudToolkitInstaller(runner: cloud.runner, toolkit: toolkit)
            .upload(toAlias: host.adminAlias)

        let setup = CloudToolkitInstaller.setupCommand(
            CloudSetupOptions(
                adminUser: "admin",
                memberUser: memberUser,
                memberHome: NSHomeDirectory(),
                memberPublicKey: memberKey,
                hostname: nil,
                installsClaude: false,
                additionalArguments: ["--container", "--minimal"]
            )
        )
        XCTAssertTrue(setup.hasPrefix("sudo "))
        let setupResult = try await cloud.runner.run(
            CloudCommand(
                alias: host.adminAlias,
                remote: .script("echo termuctive | sudo -S -p '' " + setup.dropFirst(5)),
                timeout: 600
            )
        )
        XCTAssertTrue(setupResult.succeeded, setupResult.outputText + setupResult.errorText)

        let status = try await cloud.client.status(alias: host.alias)
        XCTAssertEqual(status.user, memberUser)
        XCTAssertEqual(status.home, NSHomeDirectory())
        XCTAssertEqual(status.toolkit.protocolVersion, TMCClient.protocolVersion)

        return (store, cloud, host)
    }

    private func output(
        of terminal: TermuctiveTerminalView,
        containing marker: String,
        timeout: TimeInterval = 20
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        while Date() < deadline {
            text = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
            if text.contains(marker) {
                return text
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(marker.debugDescription). Output: \(text)")
        return text
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Condition not met within \(timeout) seconds")
    }
}

private final class E2EWorkspacePersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}

private enum ProcessRunnerSync {
    static func git(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
