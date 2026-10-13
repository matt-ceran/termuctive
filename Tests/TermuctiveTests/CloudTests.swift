import Foundation
import XCTest

@testable import Termuctive

final class ShellQuotingTests: XCTestCase {
    func testSafeArgumentsStayReadable() {
        XCTAssertEqual(
            ShellQuoting.command(["/opt/termuctive/bin/tmc", "attach", "--slug", "bluekite"]),
            "/opt/termuctive/bin/tmc attach --slug bluekite"
        )
    }

    func testUnsafeArgumentsSurviveTheRemoteShell() throws {
        let arguments = [
            "/Users/m/My Project",
            "it's",
            "$HOME",
            "`whoami`",
            "a;b|c&d",
            "",
            "line\nbreak",
        ]
        let script = "printf '%s\\0' " + ShellQuoting.command(arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let parsed = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        XCTAssertEqual(parsed, arguments)
    }
}

final class SSHConfigRendererTests: XCTestCase {
    func testHostsShareOnePinnedKeyAndIgnoreTheUsersSSHSetup() {
        let host = CloudHost(
            id: UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!,
            name: "Home Server",
            address: "192.168.1.50",
            port: 2222,
            adminUser: "admin",
            memberUser: "mattceran"
        )
        let paths = SSHPaths(directory: URL(fileURLWithPath: "/Users/m/.termuctive/ssh"))

        let config = SSHConfigRenderer.render(hosts: [host], paths: paths)

        XCTAssertTrue(
            config.contains("Host tmc-abcdef12\n    HostName 192.168.1.50\n    Port 2222"))
        XCTAssertTrue(config.contains("    User mattceran"))
        XCTAssertTrue(config.contains("Host tmc-abcdef12-admin"))
        XCTAssertTrue(config.contains("    User admin"))
        XCTAssertEqual(config.components(separatedBy: "HostKeyAlias tmc-abcdef12\n").count, 3)
        XCTAssertTrue(config.contains("IdentityFile /Users/m/.termuctive/ssh/admin_ed25519"))
        XCTAssertTrue(config.contains("    IdentitiesOnly yes\n    IdentityAgent none"))
        XCTAssertTrue(config.contains("UserKnownHostsFile /Users/m/.termuctive/ssh/known_hosts"))
        XCTAssertTrue(config.contains("ControlPath /Users/m/.termuctive/ssh/cm/%C"))
        XCTAssertFalse(config.contains("SendEnv LANG"))
    }

    func testPathsWithSpacesAreQuoted() {
        let host = CloudHost(name: "S", address: "s", adminUser: "admin", memberUser: "m")
        let paths = SSHPaths(
            directory: URL(fileURLWithPath: "/Users/Jane Doe/.termuctive/ssh"),
            controlDirectory: URL(fileURLWithPath: "/tmp/termuctive-501/cm")
        )

        let config = SSHConfigRenderer.render(hosts: [host], paths: paths)

        XCTAssertTrue(
            config.contains("IdentityFile \"/Users/Jane Doe/.termuctive/ssh/id_ed25519\""))
    }

    func testControlSocketsFitTheUnixSocketPathLimit() {
        XCTAssertLessThan(SSHPaths.live.longestControlSocketPath, SSHPaths.maximumSocketPathLength)

        let deep = SSHPaths(
            directory: URL(
                fileURLWithPath:
                    "/Users/a-very-long-account-name/Some Folder/even/deeper/nesting/ssh"
            )
        )
        XCTAssertTrue(deep.controlDirectory.path.hasPrefix("/tmp/termuctive-"))
        XCTAssertLessThan(deep.longestControlSocketPath, SSHPaths.maximumSocketPathLength)
    }
}

final class CloudModelTests: XCTestCase {
    func testSlugsAreServerSafe() {
        XCTAssertEqual(CloudSlug.make(from: "BlueKite"), "bluekite")
        XCTAssertEqual(CloudSlug.make(from: "  Voice Agent (v2) "), "voice-agent-v2")
        XCTAssertEqual(CloudSlug.make(from: "Café Ünïcode"), "cafe-unicode")
        XCTAssertEqual(CloudSlug.make(from: "!!!"), "project")
        XCTAssertTrue(CloudSlug.isValid(CloudSlug.make(from: String(repeating: "x", count: 80))))
        XCTAssertFalse(CloudSlug.isValid("-leading"))
        XCTAssertFalse(CloudSlug.isValid("Upper"))
    }

    func testOlderCloudFilesDecodeWithDefaults() throws {
        let json = """
            {"hosts": [{"id": "ABCDEF12-0000-0000-0000-000000000000", "name": "S",
              "address": "10.0.0.2", "adminUser": "admin", "memberUser": "m"}],
             "bindings": [{"projectID": "11111111-0000-0000-0000-000000000000",
              "hostID": "ABCDEF12-0000-0000-0000-000000000000", "slug": "demo",
              "remoteRoot": "/Users/m/demo"}]}
            """
        let state = try JSONDecoder().decode(CloudState.self, from: Data(json.utf8))

        XCTAssertEqual(state.schemaVersion, CloudState.currentSchemaVersion)
        XCTAssertEqual(state.hosts.first?.port, 22)
        XCTAssertEqual(state.bindings.first?.role, .owner)
        XCTAssertEqual(state.hosts.first?.alias, "tmc-abcdef12")
    }

    func testServerStatusDecodesRealToolkitOutput() throws {
        let json = """
            {"arch": "aarch64", "cpuCount": 4,
             "disk": {"freeBytes": 13311848448, "path": "/srv/termuctive", "totalBytes": 41954803712},
             "gpus": [], "home": "/Users/mattceran", "hostname": "server",
             "load": [0.1, 0.1, 0.1],
             "memory": {"availableBytes": 6949625856, "swapFreeBytes": 0, "swapTotalBytes": 0,
                        "totalBytes": 8307765248},
             "os": "Ubuntu 24.04.5 LTS",
             "projects": [{"created": 1791849155, "members": ["mattceran"], "owner": "mattceran",
                           "root": "/Users/mattceran/demo", "slug": "demo"}],
             "rebootRequired": false,
             "sessions": [{"activity": 1791849174, "attached": false, "command": "bash",
                           "created": 1791849174, "cwd": "/Users/mattceran/demo",
                           "pane": "7a48ebfc-b4d8-45d5-99a3-59ec15f31297", "pid": 1348}],
             "tailscale": {}, "toolkit": {"protocol": 1, "version": "0.1.0"},
             "tools": {"aws": null, "claude": null, "gh": null, "git": "git version 2.43.0",
                       "node": null, "python": "3.12.3", "tmux": "tmux 3.4"},
             "uptimeSeconds": 599369, "user": "mattceran"}
            """

        let status = try JSONDecoder().decode(CloudServerStatus.self, from: Data(json.utf8))

        XCTAssertEqual(status.toolkit, TMCVersion(version: "0.1.0", protocolVersion: 1))
        XCTAssertEqual(status.projects.first?.slug, "demo")
        XCTAssertEqual(
            status.sessions?.first?.pane,
            UUID(uuidString: "7A48EBFC-B4D8-45D5-99A3-59EC15F31297")
        )
        XCTAssertNil(status.tailscale.dnsName)
        XCTAssertNil(status.tools.claude)
    }
}

@MainActor
final class CloudStoreTests: XCTestCase {
    func testStateRoundTripsThroughTheSidecarFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let persistence = CloudFileStore(fileURL: directory.appendingPathComponent("cloud.json"))
        let store = CloudStore(persistence: persistence)
        let host = CloudHost(name: "S", address: "10.0.0.2", adminUser: "admin", memberUser: "m")
        let projectID = UUID()

        store.addOrUpdate(host)
        store.bind(
            CloudProjectBinding(
                projectID: projectID,
                hostID: host.id,
                slug: "demo",
                remoteRoot: "/Users/m/demo",
                role: .owner
            )
        )

        let reloaded = CloudStore(persistence: persistence)
        XCTAssertEqual(reloaded.state, store.state)
        XCTAssertEqual(reloaded.binding(forProjectID: projectID)?.slug, "demo")
    }

    func testUnreadableFilesAreNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("cloud.json")
        let unreadable = Data(#"{"schemaVersion": 99}"#.utf8)
        try unreadable.write(to: fileURL)

        let store = CloudStore(persistence: CloudFileStore(fileURL: fileURL))
        store.addOrUpdate(CloudHost(name: "S", address: "s", adminUser: "a", memberUser: "m"))

        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: fileURL), unreadable)
    }

    func testRemovingAHostForgetsItsBindings() {
        let store = CloudStore(persistence: InMemoryCloudPersistence())
        let host = CloudHost(name: "S", address: "s", adminUser: "a", memberUser: "m")
        let projectID = UUID()
        store.addOrUpdate(host)
        store.bind(
            CloudProjectBinding(
                projectID: projectID,
                hostID: host.id,
                slug: "demo",
                remoteRoot: "/x",
                role: .owner
            )
        )

        store.removeHost(withID: host.id)

        XCTAssertNil(store.binding(forProjectID: projectID))
        XCTAssertTrue(store.hosts.isEmpty)
    }
}

@MainActor
final class CloudSessionCoordinatorTests: XCTestCase {
    func testOnlyPanesInBoundProjectsLaunchOnTheServer() throws {
        let (store, project, pane) = try makeWorkspace()
        let (coordinator, _) = makeBoundCloud(store: store, projectID: project.id)
        let other = try addSecondProject(to: store)

        let launch = try XCTUnwrap(coordinator.launchSpec(for: pane).remote)
        XCTAssertEqual(launch.executable, "/usr/bin/ssh")
        XCTAssertTrue(launch.arguments.contains("-tt"))
        XCTAssertTrue(launch.arguments.contains("ControlPath=none"))
        XCTAssertEqual(launch.hostLabel, "Home Server")
        let remoteCommand = try XCTUnwrap(launch.arguments.last)
        XCTAssertTrue(remoteCommand.hasPrefix("/opt/termuctive/bin/tmc attach --protocol 1"))
        XCTAssertTrue(remoteCommand.contains("--slug demo"))
        XCTAssertTrue(remoteCommand.contains("--pane \(pane.id.uuidString.lowercased())"))
        XCTAssertTrue(remoteCommand.contains("--cwd '/Users/m/My Project'"))

        XCTAssertEqual(coordinator.launchSpec(for: other), .localShell)
    }

    func testClosingACloudPaneEndsItsServerSession() async throws {
        let (store, project, pane) = try makeWorkspace()
        let runner = RecordingCloudRunner()
        let (coordinator, _) = makeBoundCloud(store: store, projectID: project.id, runner: runner)
        store.focusPane(withID: pane.id)
        store.splitFocusedPane(axis: .horizontal)
        coordinator.workspaceTerminalsChanged()

        store.closePane(withID: pane.id)
        coordinator.workspaceTerminalsChanged()

        let kill = try await waitForCommand(in: runner) { command in
            command.remoteCommandLine.contains(" kill ")
        }
        XCTAssertEqual(
            kill.remoteCommandLine,
            "/opt/termuctive/bin/tmc kill --slug demo --pane \(pane.id.uuidString.lowercased())"
        )
    }

    func testRemovingTheProjectOnlyDetaches() async throws {
        let (store, project, _) = try makeWorkspace()
        let runner = RecordingCloudRunner()
        let (coordinator, cloudStore) = makeBoundCloud(
            store: store,
            projectID: project.id,
            runner: runner
        )

        _ = store.removeProject(withID: project.id)
        coordinator.workspaceTerminalsChanged()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(runner.commands.contains { $0.remoteCommandLine.contains(" kill ") })
        XCTAssertNil(cloudStore.binding(forProjectID: project.id))
    }

    func testDisconnectingSwitchesPanesBackToThisMac() throws {
        let (store, project, pane) = try makeWorkspace()
        let (coordinator, cloudStore) = makeBoundCloud(store: store, projectID: project.id)

        coordinator.disconnect(projectID: project.id)

        XCTAssertNil(cloudStore.binding(forProjectID: project.id))
        XCTAssertEqual(coordinator.launchSpec(for: pane), .localShell)
    }

    func testConnectingCreatesTheProjectOnTheServerAndBindsIt() async throws {
        let (store, project, pane) = try makeWorkspace()
        let runner = RecordingCloudRunner { command in
            let body =
                command.remoteCommandLine.contains("project-create")
                ? #"{"slug": "demo", "root": "/Users/m/demo", "owner": "m", "members": ["m"]}"#
                : ""
            return ProcessResult(status: 0, output: Data(body.utf8), error: Data(), timedOut: false)
        }
        let (coordinator, cloudStore) = makeTestCloud(store: store, runner: runner)
        let host = CloudHost(
            name: "Home Server",
            address: "10.0.0.2",
            adminUser: "admin",
            memberUser: "m"
        )
        cloudStore.addOrUpdate(host)

        try await coordinator.connect(
            projectID: project.id,
            host: host,
            slug: "demo",
            remoteRoot: "/Users/m/demo"
        )

        let create = try XCTUnwrap(
            runner.commands.first { $0.remoteCommandLine.contains("project-create") }
        )
        XCTAssertEqual(create.alias, host.alias)
        XCTAssertEqual(
            create.remoteCommandLine,
            "sudo -n /opt/termuctive/bin/tmc admin project-create --slug demo "
                + "--root /Users/m/demo --owner m"
        )
        XCTAssertEqual(cloudStore.binding(forProjectID: project.id)?.remoteRoot, "/Users/m/demo")
        XCTAssertNotNil(coordinator.launchSpec(for: pane).remote)
    }

    // MARK: Helpers

    private func makeWorkspace() throws -> (WorkspaceStore, TerminalProject, TerminalPane) {
        let store = WorkspaceStore(persistence: CloudTestWorkspacePersistence())
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let project = try XCTUnwrap(store.selectedProject)
        let paneID = try XCTUnwrap(store.selectedSpace?.layout.firstTerminalID)
        store.updateTerminal(paneID: paneID, workingDirectory: "/Users/m/My Project")
        let pane = try XCTUnwrap(store.document.terminal(withID: paneID))
        return (store, project, pane)
    }

    private func addSecondProject(to store: WorkspaceStore) throws -> TerminalPane {
        store.addProject(at: URL(fileURLWithPath: "/var", isDirectory: true))
        let paneID = try XCTUnwrap(store.selectedSpace?.layout.firstTerminalID)
        return try XCTUnwrap(store.document.terminal(withID: paneID))
    }

    private func makeBoundCloud(
        store: WorkspaceStore,
        projectID: UUID,
        runner: RecordingCloudRunner = RecordingCloudRunner()
    ) -> (CloudSessionCoordinator, CloudStore) {
        let host = CloudHost(
            name: "Home Server",
            address: "10.0.0.2",
            adminUser: "admin",
            memberUser: "m"
        )
        let state = CloudState(
            hosts: [host],
            bindings: [
                CloudProjectBinding(
                    projectID: projectID,
                    hostID: host.id,
                    slug: "demo",
                    remoteRoot: "/Users/m/demo",
                    role: .owner
                )
            ]
        )
        return makeTestCloud(store: store, state: state, runner: runner)
    }

    private func waitForCommand(
        in runner: RecordingCloudRunner,
        matching predicate: (CloudCommand) -> Bool
    ) async throws -> CloudCommand {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let command = runner.commands.first(where: predicate) {
                return command
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("No matching command was run")
        throw CloudCommandError.timedOut(command: "")
    }
}

final class CloudToolkitTests: XCTestCase {
    private var resourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    func testTheToolkitArchiveContainsTheInstallerAndNoCaches() async throws {
        let toolkit = try XCTUnwrap(CloudToolkit.bundled(in: resourceDirectory))
        XCTAssertNotNil(toolkit.version)

        let archive = try await toolkit.archive()
        let listing = try await ProcessRunner.run("/usr/bin/tar", ["-tzf", "-"], input: archive)

        XCTAssertTrue(listing.succeeded, listing.errorText)
        let entries = listing.outputText.split(separator: "\n").map(String.init)
        XCTAssertTrue(entries.contains("./bootstrap.sh"))
        XCTAssertTrue(entries.contains("./bin/tmc"))
        XCTAssertTrue(entries.contains("./share/tmux.conf"))
        XCTAssertFalse(entries.contains { $0.contains("__pycache__") || $0.contains("._") })
    }

    func testTheSetupCommandQuotesEveryValue() {
        let command = CloudToolkitInstaller.setupCommand(
            CloudSetupOptions(
                adminUser: "admin",
                memberUser: "mattceran",
                memberHome: "/Users/mattceran",
                memberPublicKey: "ssh-ed25519 AAAAC3Nza termuctive-member-matt",
                hostname: "termuctive",
                installsDocker: true,
                installsAWSCLI: false
            )
        )

        XCTAssertEqual(
            command,
            "sudo sh ~/.termuctive-toolkit/bootstrap.sh --admin-user admin --member mattceran "
                + "--member-home /Users/mattceran "
                + "--member-key 'ssh-ed25519 AAAAC3Nza termuctive-member-matt' "
                + "--hostname termuctive --with-docker --skip-awscli"
        )
    }
}

private final class CloudTestWorkspacePersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
