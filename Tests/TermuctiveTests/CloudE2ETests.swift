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
