import Foundation

struct RemoteSessionReport: Decodable, Equatable {
    struct Claude: Decodable, Equatable {
        let state: String?
        let sessionId: String?
        let lastPrompt: String?
        let notification: String?
        let ended: Bool?
    }

    struct Process: Decodable, Equatable {
        let pid: Int
        let name: String
        let executable: String
        let arguments: [String]
    }

    let pane: UUID
    let activity: Int
    let attached: Bool
    let command: String
    let cwd: String
    let claude: Claude?
    let processes: [Process]
}

/// Turns what the server reports about cloud sessions into the same activity signals
/// local terminals produce, for every cloud pane, including panes not on screen.
@MainActor
final class CloudActivityBridge {
    /// Output this recent counts as an agent working, for agents without hooks.
    nonisolated static let recentOutputWindow: TimeInterval = 4

    weak var registry: AgentActivityRegistry?
    var notify: (_ title: String, _ body: String) -> Void = { _, _ in }

    private let store: WorkspaceStore
    private let cloudStore: CloudStore
    private let runner: any CloudCommandRunning
    private let control: any CloudControlling
    private let now: () -> Date
    private var sessionIDs: [UUID: UUID] = [:]
    private var claudeStates: [UUID: String] = [:]
    private var loop: Task<Void, Never>?

    init(
        store: WorkspaceStore,
        cloudStore: CloudStore,
        runner: any CloudCommandRunning,
        control: any CloudControlling,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.cloudStore = cloudStore
        self.runner = runner
        self.control = control
        self.now = now
    }

    func start(interval: TimeInterval = 3) {
        guard loop == nil else {
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func refresh() async {
        var seenPanes = Set<UUID>()
        for binding in cloudStore.state.bindings {
            guard
                let project = store.document.projects.first(where: { $0.id == binding.projectID }),
                let host = cloudStore.host(withID: binding.hostID)
            else {
                continue
            }
            let paneIDs = project.items.reduce(into: Set<UUID>()) { $0.formUnion($1.terminalIDs) }
            seenPanes.formUnion(paneIDs)
            await control.ensureMaster(alias: host.alias)
            guard
                let reports = try? await runner.decode(
                    [RemoteSessionReport].self,
                    CloudCommand(
                        alias: host.alias,
                        remote: .arguments([
                            TMCClient.executable, "sessions", "--slug", binding.slug,
                        ])
                    )
                )
            else {
                continue
            }
            let byPane = Dictionary(reports.map { ($0.pane, $0) }, uniquingKeysWith: { a, _ in a })
            for paneID in paneIDs {
                apply(byPane[paneID], paneID: paneID, projectName: project.name)
            }
        }
        for paneID in Array(sessionIDs.keys) where !seenPanes.contains(paneID) {
            end(paneID)
        }
    }

    private func apply(_ report: RemoteSessionReport?, paneID: UUID, projectName: String) {
        guard let report else {
            end(paneID)
            return
        }
        let sessionID: UUID
        if let existing = sessionIDs[paneID] {
            sessionID = existing
        } else {
            sessionID = UUID()
            sessionIDs[paneID] = sessionID
            registry?.beginSession(paneID: paneID, sessionID: sessionID)
        }
        registry?.setActivity(
            Self.activity(for: report, now: now()),
            paneID: paneID,
            sessionID: sessionID
        )

        if !report.cwd.isEmpty,
            let pane = store.document.terminal(withID: paneID),
            pane.workingDirectory != report.cwd
        {
            store.updateTerminal(paneID: paneID, workingDirectory: report.cwd)
        }

        let state = report.claude?.state ?? ""
        if state == "waiting", claudeStates[paneID] != "waiting" {
            notify(
                "Claude needs your attention",
                "\(projectName): \(report.claude?.notification ?? "waiting for permission")"
            )
        }
        claudeStates[paneID] = state
    }

    private func end(_ paneID: UUID) {
        guard let sessionID = sessionIDs.removeValue(forKey: paneID) else {
            return
        }
        claudeStates.removeValue(forKey: paneID)
        registry?.endSession(paneID: paneID, sessionID: sessionID)
    }

    nonisolated static func activity(
        for report: RemoteSessionReport,
        now: Date
    ) -> TerminalAgentActivity {
        var kinds = Set(
            report.processes.compactMap { process in
                TerminalAgentProcessMatcher.kind(
                    for: AgentProcessRecord(
                        processID: Int32(clamping: process.pid),
                        executablePath: process.executable,
                        processName: process.name,
                        arguments: process.arguments
                    )
                )
            }
        )
        let claude = report.claude
        let claudeRunning = claude.map { $0.ended != true && $0.state != nil } ?? false
        if claudeRunning {
            kinds.insert(.claude)
        }
        guard !kinds.isEmpty else {
            return .absent
        }
        let busy = claude?.state == "working" || claude?.state == "waiting"
        let recentOutput =
            now.timeIntervalSince1970 - Double(report.activity) < recentOutputWindow
        return busy || recentOutput ? .active(kinds) : .absent
    }
}
