import Foundation

enum PaneAxis: String, Codable, CaseIterable {
    case horizontal
    case vertical
}

struct TerminalPane: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var workingDirectory: String

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        workingDirectory: String
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
    }
}

struct PaneSplit: Codable, Equatable, Identifiable {
    let id: UUID
    let axis: PaneAxis
    var first: PaneNode
    var second: PaneNode
    var ratio: Double

    init(
        id: UUID = UUID(),
        axis: PaneAxis,
        first: PaneNode,
        second: PaneNode,
        ratio: Double = 0.5
    ) {
        self.id = id
        self.axis = axis
        self.first = first
        self.second = second
        self.ratio = ratio.clamped(to: 0.1...0.9)
    }
}

indirect enum PaneNode: Codable, Equatable, Identifiable {
    case terminal(TerminalPane)
    case split(PaneSplit)

    var id: UUID {
        switch self {
        case .terminal(let pane):
            pane.id
        case .split(let split):
            split.id
        }
    }

    var terminalCount: Int {
        switch self {
        case .terminal:
            1
        case .split(let split):
            split.first.terminalCount + split.second.terminalCount
        }
    }

    var firstTerminalID: UUID {
        switch self {
        case .terminal(let pane):
            pane.id
        case .split(let split):
            split.first.firstTerminalID
        }
    }

    var terminalIDs: Set<UUID> {
        switch self {
        case .terminal(let pane):
            [pane.id]
        case .split(let split):
            split.first.terminalIDs.union(split.second.terminalIDs)
        }
    }

    func terminal(withID id: UUID) -> TerminalPane? {
        switch self {
        case .terminal(let pane):
            pane.id == id ? pane : nil
        case .split(let split):
            split.first.terminal(withID: id) ?? split.second.terminal(withID: id)
        }
    }

    func splittingTerminal(
        withID id: UUID,
        axis: PaneAxis,
        newPane: TerminalPane
    ) -> PaneNode? {
        switch self {
        case .terminal(let pane):
            guard pane.id == id else {
                return nil
            }

            return .split(
                PaneSplit(
                    axis: axis,
                    first: self,
                    second: .terminal(newPane)
                )
            )

        case .split(var split):
            if let first = split.first.splittingTerminal(
                withID: id,
                axis: axis,
                newPane: newPane
            ) {
                split.first = first
                return .split(split)
            }

            if let second = split.second.splittingTerminal(
                withID: id,
                axis: axis,
                newPane: newPane
            ) {
                split.second = second
                return .split(split)
            }

            return nil
        }
    }

    func removingTerminal(withID id: UUID) -> PaneNode? {
        guard terminalIDs.contains(id) else {
            return self
        }

        return removingContainedTerminal(withID: id)
    }

    func settingRatio(forSplitID id: UUID, to ratio: Double) -> PaneNode {
        switch self {
        case .terminal:
            return self
        case .split(var split):
            if split.id == id {
                split.ratio = ratio.clamped(to: 0.1...0.9)
                return .split(split)
            }

            split.first = split.first.settingRatio(forSplitID: id, to: ratio)
            split.second = split.second.settingRatio(forSplitID: id, to: ratio)
            return .split(split)
        }
    }

    func updatingTerminal(
        withID id: UUID,
        title: String? = nil,
        workingDirectory: String? = nil
    ) -> PaneNode {
        switch self {
        case .terminal(var pane):
            guard pane.id == id else {
                return self
            }

            if let title, !title.isEmpty {
                pane.title = title
            }
            if let workingDirectory, !workingDirectory.isEmpty {
                pane.workingDirectory = workingDirectory
            }
            return .terminal(pane)

        case .split(var split):
            split.first = split.first.updatingTerminal(
                withID: id,
                title: title,
                workingDirectory: workingDirectory
            )
            split.second = split.second.updatingTerminal(
                withID: id,
                title: title,
                workingDirectory: workingDirectory
            )
            return .split(split)
        }
    }

    private func removingContainedTerminal(withID id: UUID) -> PaneNode? {
        switch self {
        case .terminal(let pane):
            return pane.id == id ? nil : self

        case .split(var split):
            if split.first.terminalIDs.contains(id) {
                guard let first = split.first.removingContainedTerminal(withID: id) else {
                    return split.second
                }
                split.first = first
                return .split(split)
            }

            guard let second = split.second.removingContainedTerminal(withID: id) else {
                return split.first
            }
            split.second = second
            return .split(split)
        }
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
