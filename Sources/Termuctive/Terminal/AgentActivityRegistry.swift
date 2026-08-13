import Combine
import Foundation

enum AgentActivityScope: Hashable {
    case folder(UUID)
    case pane(UUID)
    case project(UUID)
    case space(UUID)
}

struct AgentActivitySummary: Equatable {
    let phase: TerminalAgentActivityPhase
    let kinds: Set<TerminalAgentKind>
    let sessionCount: Int

    static let absent = AgentActivitySummary(
        phase: .absent,
        kinds: [],
        sessionCount: 0
    )

    var sortedKinds: [TerminalAgentKind] {
        kinds.sorted { $0.displayName < $1.displayName }
    }

    var helpText: String {
        guard phase != .absent else {
            return ""
        }
        if sessionCount > 1 {
            return "\(sessionCount) agent sessions are active"
        }

        let names = sortedKinds.map(\.displayName)
        let agentName = names.count == 1 ? names[0] : names.joined(separator: " and ")
        return "\(agentName) is active"
    }

    var accessibilityValue: String {
        guard phase != .absent else {
            return ""
        }
        if sessionCount > 1 {
            return "\(sessionCount) agent sessions active"
        }
        let names = sortedKinds.map(\.displayName)
        let agentName = names.count == 1 ? names[0] : names.joined(separator: " and ")
        return "\(agentName) active"
    }
}

@MainActor
final class AgentActivitySignal: ObservableObject {
    @Published private(set) var summary: AgentActivitySummary

    init(summary: AgentActivitySummary = .absent) {
        self.summary = summary
    }

    fileprivate func setSummary(_ summary: AgentActivitySummary) {
        guard self.summary != summary else {
            return
        }
        self.summary = summary
    }
}

struct WorkspaceActivityTopology: Equatable {
    fileprivate let paneScopes: [UUID: Set<AgentActivityScope>]
    fileprivate let scopePaneIDs: [AgentActivityScope: Set<UUID>]

    init() {
        paneScopes = [:]
        scopePaneIDs = [:]
    }

    init(document: WorkspaceDocument) {
        var paneScopes: [UUID: Set<AgentActivityScope>] = [:]
        var scopePaneIDs: [AgentActivityScope: Set<UUID>] = [:]

        func register(
            paneID: UUID,
            projectID: UUID,
            spaceID: UUID,
            folderIDs: [UUID]
        ) {
            var scopes: Set<AgentActivityScope> = [
                .pane(paneID),
                .project(projectID),
                .space(spaceID),
            ]
            scopes.formUnion(folderIDs.map(AgentActivityScope.folder))
            paneScopes[paneID] = scopes
            for scope in scopes {
                scopePaneIDs[scope, default: []].insert(paneID)
            }
        }

        func walk(
            _ item: WorkspaceItem,
            projectID: UUID,
            folderIDs: [UUID]
        ) {
            switch item {
            case .folder(let folder):
                let descendants = folderIDs + [folder.id]
                for child in folder.children {
                    walk(child, projectID: projectID, folderIDs: descendants)
                }
            case .note:
                break
            case .space(let space):
                for paneID in space.layout.orderedTerminalIDs {
                    guard space.layout.terminal(withID: paneID)?.content == .terminal else {
                        continue
                    }
                    register(
                        paneID: paneID,
                        projectID: projectID,
                        spaceID: space.id,
                        folderIDs: folderIDs
                    )
                }
            }
        }

        for project in document.projects {
            for item in project.items {
                walk(item, projectID: project.id, folderIDs: [])
            }
        }

        self.paneScopes = paneScopes
        self.scopePaneIDs = scopePaneIDs
    }
}

@MainActor
final class AgentActivityRegistry: ObservableObject {
    private var topology = WorkspaceActivityTopology(document: WorkspaceDocument())
    private var activeSessionIDs: [UUID: UUID] = [:]
    private var paneActivities: [UUID: TerminalAgentActivity] = [:]
    private var signals: [AgentActivityScope: AgentActivitySignal] = [:]

    func signal(for scope: AgentActivityScope) -> AgentActivitySignal {
        if let signal = signals[scope] {
            return signal
        }
        let signal = AgentActivitySignal(summary: summary(for: scope))
        signals[scope] = signal
        return signal
    }

    func reconcile(topology: WorkspaceActivityTopology) {
        guard self.topology != topology else {
            return
        }
        let oldTopology = self.topology
        let affectedScopes = Set(oldTopology.scopePaneIDs.keys)
            .union(topology.scopePaneIDs.keys)
        let removedPaneIDs = Set(oldTopology.paneScopes.keys)
            .subtracting(topology.paneScopes.keys)
        let removedScopes = Set(oldTopology.scopePaneIDs.keys)
            .subtracting(topology.scopePaneIDs.keys)
        self.topology = topology
        for paneID in removedPaneIDs {
            paneActivities.removeValue(forKey: paneID)
            activeSessionIDs.removeValue(forKey: paneID)
        }
        updateSignals(for: affectedScopes)
        for scope in removedScopes {
            signals.removeValue(forKey: scope)
        }
    }

    func beginSession(paneID: UUID, sessionID: UUID) {
        activeSessionIDs[paneID] = sessionID
        paneActivities.removeValue(forKey: paneID)
        updateSignals(forPaneID: paneID)
    }

    func endSession(paneID: UUID, sessionID: UUID) {
        guard activeSessionIDs[paneID] == sessionID else {
            return
        }
        activeSessionIDs.removeValue(forKey: paneID)
        paneActivities.removeValue(forKey: paneID)
        updateSignals(forPaneID: paneID)
    }

    func setActivity(
        _ activity: TerminalAgentActivity,
        paneID: UUID,
        sessionID: UUID
    ) {
        guard activeSessionIDs[paneID] == sessionID else {
            return
        }

        if activity.phase == .absent {
            guard paneActivities.removeValue(forKey: paneID) != nil else {
                return
            }
        } else {
            guard paneActivities[paneID] != activity else {
                return
            }
            paneActivities[paneID] = activity
        }
        updateSignals(forPaneID: paneID)
    }

    func clearAllSessions() {
        let affectedScopes = Set(topology.scopePaneIDs.keys)
        activeSessionIDs.removeAll()
        paneActivities.removeAll()
        updateSignals(for: affectedScopes)
    }

    private func updateSignals(forPaneID paneID: UUID) {
        updateSignals(for: topology.paneScopes[paneID] ?? [])
    }

    private func updateSignals(for scopes: Set<AgentActivityScope>) {
        for scope in scopes {
            signals[scope]?.setSummary(summary(for: scope))
        }
    }

    private func summary(for scope: AgentActivityScope) -> AgentActivitySummary {
        let paneIDs = topology.scopePaneIDs[scope] ?? []
        let activities = paneIDs.compactMap { paneActivities[$0] }
        guard !activities.isEmpty else {
            return .absent
        }
        return AgentActivitySummary(
            phase: .active,
            kinds: activities.reduce(into: Set<TerminalAgentKind>()) {
                $0.formUnion($1.kinds)
            },
            sessionCount: activities.count
        )
    }
}
