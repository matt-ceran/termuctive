import AppKit
import Foundation
import XCTest

@testable import Termuctive

final class CloudActivityClassificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testClaudeHookStatesDecideWhetherTheAgentIsWorking() {
        XCTAssertEqual(
            CloudActivityBridge.activity(
                for: report(claudeState: "working", activityAgo: 60), now: now),
            .active([.claude])
        )
        XCTAssertEqual(
            CloudActivityBridge.activity(
                for: report(claudeState: "waiting", activityAgo: 60), now: now),
            .active([.claude])
        )
        XCTAssertEqual(
            CloudActivityBridge.activity(
                for: report(claudeState: "idle", activityAgo: 60), now: now),
            .absent
        )
    }

    func testOtherAgentsAreRecognizedByProcessAndRecentOutput() {
        let codex = RemoteSessionReport.Process(
            pid: 42,
            name: "node",
            executable: "/usr/bin/node",
            arguments: ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js"]
        )
        XCTAssertEqual(
            CloudActivityBridge.activity(
                for: report(claudeState: nil, activityAgo: 1, processes: [codex]),
                now: now
            ),
            .active([.codex])
        )
        XCTAssertEqual(
            CloudActivityBridge.activity(
                for: report(claudeState: nil, activityAgo: 30, processes: [codex]),
                now: now
            ),
            .absent
        )
        XCTAssertEqual(
            CloudActivityBridge.activity(for: report(claudeState: nil, activityAgo: 1), now: now),
            .absent
        )
    }

    private func report(
        claudeState: String?,
        activityAgo: TimeInterval,
        processes: [RemoteSessionReport.Process] = []
    ) -> RemoteSessionReport {
        RemoteSessionReport(
            pane: UUID(),
            activity: Int(now.timeIntervalSince1970 - activityAgo),
            attached: true,
            command: "bash",
            cwd: "/x",
            claude: claudeState.map {
                RemoteSessionReport.Claude(
                    state: $0,
                    sessionId: "s",
                    lastPrompt: nil,
                    notification: nil,
                    ended: false
                )
            },
            processes: processes
        )
    }
}

@MainActor
final class CloudActivityBridgeTests: XCTestCase {
    func testServerReportsDriveSidebarActivityFolderAndNotifications() async throws {
        let store = WorkspaceStore(persistence: ActivityTestPersistence())
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let project = try XCTUnwrap(store.selectedProject)
        let space = try XCTUnwrap(store.selectedSpace)
        let paneID = space.layout.firstTerminalID
        let host = CloudHost(name: "S", address: "s", adminUser: "a", memberUser: "m")
        let cloudStore = CloudStore(
            persistence: InMemoryCloudPersistence(
                initialState: CloudState(
                    hosts: [host],
                    bindings: [
                        CloudProjectBinding(
                            projectID: project.id,
                            hostID: host.id,
                            slug: "demo",
                            remoteRoot: "/x",
                            role: .owner
                        )
                    ]
                )
            )
        )
        let response = ActivityResponse()
        let runner = RecordingCloudRunner { _ in
            ProcessResult(
                status: 0, output: Data(response.json.utf8), error: Data(), timedOut: false)
        }
        let registry = AgentActivityRegistry()
        registry.reconcile(topology: WorkspaceActivityTopology(document: store.document))
        let bridge = CloudActivityBridge(
            store: store,
            cloudStore: cloudStore,
            runner: runner,
            control: NoOpCloudControl()
        )
        bridge.registry = registry
        var notifications: [String] = []
        bridge.notify = { title, body in notifications.append("\(title) | \(body)") }
        let spaceSignal = registry.signal(for: .space(space.id))

        response.json = Self.sessions(paneID: paneID, state: "working", cwd: "/x/src")
        await bridge.refresh()
        XCTAssertEqual(spaceSignal.summary.phase, .active)
        XCTAssertEqual(spaceSignal.summary.kinds, [.claude])
        XCTAssertEqual(store.document.terminal(withID: paneID)?.workingDirectory, "/x/src")
        XCTAssertTrue(notifications.isEmpty)

        response.json = Self.sessions(paneID: paneID, state: "waiting", cwd: "/x/src")
        await bridge.refresh()
        await bridge.refresh()
        XCTAssertEqual(notifications.count, 1)
        XCTAssertTrue(notifications[0].contains("Needs approval to run tests"))

        response.json = Self.sessions(paneID: paneID, state: "idle", cwd: "/x/src")
        await bridge.refresh()
        XCTAssertEqual(spaceSignal.summary, .absent)

        response.json = "[]"
        await bridge.refresh()
        XCTAssertEqual(spaceSignal.summary, .absent)
        XCTAssertTrue(
            runner.commands.allSatisfy {
                $0.remoteCommandLine == "/opt/termuctive/bin/tmc sessions --slug demo"
            }
        )
    }

    private static func sessions(paneID: UUID, state: String, cwd: String) -> String {
        """
        [{"pane": "\(paneID.uuidString.lowercased())", "activity": 0, "attached": true,
          "command": "claude", "cwd": "\(cwd)", "pid": 10, "created": 0,
          "claude": {"state": "\(state)", "sessionId": "abc",
                     "notification": "Needs approval to run tests"},
          "processes": []}]
        """
    }
}

private final class ActivityResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "[]"

    var json: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class ActivityTestPersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
