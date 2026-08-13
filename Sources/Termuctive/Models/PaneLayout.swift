import Foundation

enum PaneAxis: String, Codable, CaseIterable {
    case horizontal
    case vertical
}

enum PaneInsertionPlacement {
    case before
    case after
}

enum PaneContent: Codable, Equatable {
    case terminal
    case note(UUID)
}

struct TerminalPane: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var workingDirectory: String
    var content: PaneContent

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        workingDirectory: String,
        content: PaneContent = .terminal
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case workingDirectory
        case content
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        content = try container.decodeIfPresent(PaneContent.self, forKey: .content) ?? .terminal
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(content, forKey: .content)
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

    var orderedTerminalIDs: [UUID] {
        switch self {
        case .terminal(let pane):
            [pane.id]
        case .split(let split):
            split.first.orderedTerminalIDs + split.second.orderedTerminalIDs
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

    func pane(showingNoteWithID noteID: UUID) -> TerminalPane? {
        switch self {
        case .terminal(let pane):
            guard case .note(let displayedNoteID) = pane.content,
                displayedNoteID == noteID
            else {
                return nil
            }
            return pane
        case .split(let split):
            return split.first.pane(showingNoteWithID: noteID)
                ?? split.second.pane(showingNoteWithID: noteID)
        }
    }

    func splittingTerminal(
        withID id: UUID,
        axis: PaneAxis,
        newPane: TerminalPane,
        placement: PaneInsertionPlacement = .after
    ) -> PaneNode? {
        switch self {
        case .terminal(let pane):
            guard pane.id == id else {
                return nil
            }

            return .split(
                PaneSplit(
                    axis: axis,
                    first: placement == .before ? .terminal(newPane) : self,
                    second: placement == .before ? self : .terminal(newPane)
                )
            )

        case .split(var split):
            if let first = split.first.splittingTerminal(
                withID: id,
                axis: axis,
                newPane: newPane,
                placement: placement
            ) {
                split.first = first
                return .split(split)
            }

            if let second = split.second.splittingTerminal(
                withID: id,
                axis: axis,
                newPane: newPane,
                placement: placement
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

    func settingContent(forPaneID id: UUID, to content: PaneContent) -> PaneNode {
        switch self {
        case .terminal(var pane):
            guard pane.id == id else {
                return self
            }
            pane.content = content
            return .terminal(pane)

        case .split(var split):
            split.first = split.first.settingContent(forPaneID: id, to: content)
            split.second = split.second.settingContent(forPaneID: id, to: content)
            return .split(split)
        }
    }

    func clearingNoteReferences(in noteIDs: Set<UUID>) -> PaneNode {
        switch self {
        case .terminal(var pane):
            guard case .note(let noteID) = pane.content,
                noteIDs.contains(noteID)
            else {
                return self
            }
            pane.content = .terminal
            return .terminal(pane)

        case .split(var split):
            split.first = split.first.clearingNoteReferences(in: noteIDs)
            split.second = split.second.clearingNoteReferences(in: noteIDs)
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
