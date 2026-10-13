import AppKit
import XCTest

@testable import Termuctive

final class TerminalReconnectPolicyTests: XCTestCase {
    func testWaitStatusesDecodeIntoExitsAndSignals() {
        XCTAssertEqual(TerminalProcessExit(waitStatus: 0), .exited(0))
        XCTAssertEqual(TerminalProcessExit(waitStatus: 3 << 8), .exited(3))
        XCTAssertEqual(TerminalProcessExit(waitStatus: 255 << 8), .exited(255))
        XCTAssertEqual(TerminalProcessExit(waitStatus: SIGTERM), .signaled(SIGTERM))
        XCTAssertEqual(TerminalProcessExit(waitStatus: nil), .unknown)
    }

    func testDecisionsFollowTheAttachExitCodeProtocol() {
        let policy = TerminalReconnectPolicy(
            initialDelay: 1,
            maximumDelay: 30,
            maximumJitter: 0
        )

        XCTAssertEqual(policy.decision(for: .exited(0), attempt: 0, jitterFraction: 0), .finished)
        XCTAssertEqual(policy.decision(for: .exited(1), attempt: 0, jitterFraction: 0), .finished)
        XCTAssertEqual(
            policy.decision(for: .exited(3), attempt: 1, jitterFraction: 0),
            .reconnect(after: 0)
        )
        XCTAssertEqual(
            policy.decision(for: .exited(3), attempt: 3, jitterFraction: 0),
            .reconnect(after: 8)
        )
        XCTAssertEqual(
            policy.decision(for: .exited(4), attempt: 0, jitterFraction: 0),
            .serverUpdateRequired
        )
        XCTAssertEqual(
            policy.decision(for: .exited(255), attempt: 2, jitterFraction: 0),
            .reconnect(after: 4)
        )
        XCTAssertEqual(
            policy.decision(for: .signaled(SIGHUP), attempt: 0, jitterFraction: 0),
            .reconnect(after: 1)
        )
    }

    func testDelayBacksOffExponentiallyAndCapsWithJitter() {
        let policy = TerminalReconnectPolicy(
            initialDelay: 1,
            maximumDelay: 30,
            maximumJitter: 2
        )

        XCTAssertEqual(
            (0...6).map { policy.delay(forAttempt: $0, jitterFraction: 0) },
            [1, 2, 4, 8, 16, 30, 30]
        )
        XCTAssertEqual(policy.delay(forAttempt: 0, jitterFraction: 1), 3)
        XCTAssertEqual(policy.delay(forAttempt: 9, jitterFraction: 1), 30)
        XCTAssertEqual(policy.delay(forAttempt: 1, jitterFraction: 7), 4)
    }

    func testStableConnectionsResetTheAttemptCounter() {
        let policy = TerminalReconnectPolicy(stableConnectionDuration: 15)

        XCTAssertEqual(policy.nextAttempt(after: 4, connectionDuration: 2), 5)
        XCTAssertEqual(policy.nextAttempt(after: 4, connectionDuration: 15), 0)
    }
}

@MainActor
final class TerminalLaunchSpecTests: XCTestCase {
    func testRemotePaneLaunchesWithArgumentsWithoutReplacingItsDirectory() async throws {
        let remoteDirectory = "/termuctive-remote-\(UUID().uuidString)/project"
        let (store, pane) = try makeStore(workingDirectory: remoteDirectory)
        let sessions = TerminalSessionPool(
            store: store,
            launchResolver: { _ in
                .remote(
                    Self.remoteLaunch(
                        script: "printf 'ARGS:%s|%s\\n' \"$1\" \"$2\"; sleep 30",
                        arguments: ["a", "b c"]
                    )
                )
            }
        )
        defer {
            sessions.terminateAll()
        }

        let terminal = sessions.terminalView(for: pane)
        terminal.frame = NSRect(x: 0, y: 0, width: 640, height: 480)

        let output = try await terminalOutput(from: terminal, containing: "ARGS:a|b c")
        XCTAssertTrue(output.contains("ARGS:a|b c"), "Terminal output was \(output)")
        XCTAssertEqual(store.document.terminal(withID: pane.id)?.workingDirectory, remoteDirectory)
        XCTAssertEqual(sessions.status(for: pane.id), .running)
    }

    func testRemotePaneReconnectsAfterConnectionFailures() async throws {
        let counter = try makeCounterFile()
        let (store, pane) = try makeStore(workingDirectory: "/remote")
        let sessions = TerminalSessionPool(
            store: store,
            launchResolver: { _ in
                .remote(
                    Self.remoteLaunch(
                        script: "echo run >> \"$1\"; exit 255",
                        arguments: [counter.path],
                        policy: Self.fastPolicy
                    )
                )
            },
            reconnectJitter: { 0 }
        )
        defer {
            sessions.terminateAll()
        }

        _ = sessions.terminalView(for: pane)

        try await waitUntil { (try? Self.lineCount(of: counter)) ?? 0 >= 3 }
        switch sessions.status(for: pane.id) {
        case .reconnecting, .running:
            break
        case let status:
            XCTFail("Unexpected status \(status)")
        }
    }

    func testRemotePaneReportsAnIncompatibleServer() async throws {
        let (store, pane) = try makeStore(workingDirectory: "/remote")
        let sessions = TerminalSessionPool(
            store: store,
            launchResolver: { _ in
                .remote(Self.remoteLaunch(script: "exit 4", policy: Self.fastPolicy))
            }
        )
        defer {
            sessions.terminateAll()
        }

        _ = sessions.terminalView(for: pane)

        try await waitUntil { sessions.status(for: pane.id) == .serverUpdateRequired }
    }

    func testRemoteShellExitLeavesThePaneExited() async throws {
        let (store, pane) = try makeStore(workingDirectory: "/remote")
        let sessions = TerminalSessionPool(
            store: store,
            launchResolver: { _ in
                .remote(Self.remoteLaunch(script: "exit 0", policy: Self.fastPolicy))
            }
        )
        defer {
            sessions.terminateAll()
        }

        _ = sessions.terminalView(for: pane)

        try await waitUntil {
            if case .exited = sessions.status(for: pane.id) {
                return true
            }
            return false
        }
    }

    func testRelaunchingRemotePanesKeepsTheSameView() async throws {
        let counter = try makeCounterFile()
        let (store, pane) = try makeStore(workingDirectory: "/remote")
        let sessions = TerminalSessionPool(
            store: store,
            launchResolver: { _ in
                .remote(
                    Self.remoteLaunch(
                        script: "echo run >> \"$1\"; sleep 30",
                        arguments: [counter.path]
                    )
                )
            }
        )
        defer {
            sessions.terminateAll()
        }

        let terminal = sessions.terminalView(for: pane)
        try await waitUntil { (try? Self.lineCount(of: counter)) == 1 }

        sessions.relaunchRemotePanes()

        try await waitUntil { (try? Self.lineCount(of: counter)) == 2 }
        XCTAssertTrue(sessions.terminalView(for: pane) === terminal)
        XCTAssertEqual(sessions.status(for: pane.id), .running)
    }

    func testRelaunchingRemotePanesLeavesLocalShellsAlone() async throws {
        let (store, pane) = try makeStore(workingDirectory: "/tmp")
        let sessions = TerminalSessionPool(store: store)
        defer {
            sessions.terminateAll()
        }

        let terminal = sessions.terminalView(for: pane)
        let shellPID = terminal.process.shellPid

        sessions.relaunchRemotePanes()

        XCTAssertEqual(terminal.process.shellPid, shellPID)
        XCTAssertTrue(terminal.process.running)
    }

    private static let fastPolicy = TerminalReconnectPolicy(
        initialDelay: 0.05,
        maximumDelay: 0.2,
        maximumJitter: 0
    )

    private static func remoteLaunch(
        script: String,
        arguments: [String] = [],
        policy: TerminalReconnectPolicy = TerminalReconnectPolicy()
    ) -> RemoteTerminalLaunch {
        RemoteTerminalLaunch(
            executable: "/bin/sh",
            arguments: ["-c", script, "sh"] + arguments,
            hostLabel: "test-host",
            reconnectPolicy: policy
        )
    }

    private static func lineCount(of url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .count
    }

    private func makeStore(
        workingDirectory: String
    ) throws -> (WorkspaceStore, TerminalPane) {
        let store = WorkspaceStore(persistence: LaunchSpecTestPersistence())
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let paneID = layout.firstTerminalID
        store.updateTerminal(paneID: paneID, workingDirectory: workingDirectory)
        let pane = try XCTUnwrap(store.document.terminal(withID: paneID))
        return (store, pane)
    }

    private func makeCounterFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termuctive-launch-\(UUID().uuidString)")
        try Data().write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Condition was not met within \(timeout) seconds")
    }

    private func terminalOutput(
        from terminal: TermuctiveTerminalView,
        containing marker: String
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        var output = ""
        while Date() < deadline {
            output = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
            if output.contains(marker) {
                return output
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return output
    }
}

private final class LaunchSpecTestPersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
