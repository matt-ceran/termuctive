import Foundation

struct TerminalSpace: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var layout: PaneNode

    init(id: UUID = UUID(), name: String, layout: PaneNode) {
        self.id = id
        self.name = name
        self.layout = layout
    }
}

struct WorkspaceFolder: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var children: [WorkspaceItem]

    init(id: UUID = UUID(), name: String, children: [WorkspaceItem] = []) {
        self.id = id
        self.name = name
        self.children = children
    }
}

indirect enum WorkspaceItem: Codable, Equatable, Identifiable {
    case folder(WorkspaceFolder)
    case space(TerminalSpace)

    var id: UUID {
        switch self {
        case .folder(let folder):
            folder.id
        case .space(let space):
            space.id
        }
    }

    var name: String {
        switch self {
        case .folder(let folder):
            folder.name
        case .space(let space):
            space.name
        }
    }

    var firstSpace: TerminalSpace? {
        switch self {
        case .space(let space):
            space
        case .folder(let folder):
            folder.children.lazy.compactMap(\.firstSpace).first
        }
    }

    var terminalIDs: Set<UUID> {
        switch self {
        case .space(let space):
            return space.layout.terminalIDs
        case .folder(let folder):
            return folder.children.reduce(into: Set<UUID>()) { ids, child in
                ids.formUnion(child.terminalIDs)
            }
        }
    }

    var terminalSpaces: [TerminalSpace] {
        switch self {
        case .space(let space):
            [space]
        case .folder(let folder):
            folder.children.flatMap(\.terminalSpaces)
        }
    }

    var folderIDs: Set<UUID> {
        switch self {
        case .space:
            return []
        case .folder(let folder):
            return folder.children.reduce(into: Set([folder.id])) { ids, child in
                ids.formUnion(child.folderIDs)
            }
        }
    }

    func space(withID id: UUID) -> TerminalSpace? {
        switch self {
        case .space(let space):
            space.id == id ? space : nil
        case .folder(let folder):
            folder.children.lazy.compactMap { $0.space(withID: id) }.first
        }
    }

    func terminal(withID id: UUID) -> TerminalPane? {
        switch self {
        case .space(let space):
            return space.layout.terminal(withID: id)
        case .folder(let folder):
            return folder.children.lazy.compactMap { $0.terminal(withID: id) }.first
        }
    }

    func ancestorFolderIDs(forSpaceWithID id: UUID) -> [UUID]? {
        switch self {
        case .space(let space):
            return space.id == id ? [] : nil
        case .folder(let folder):
            for child in folder.children {
                if let ancestors = child.ancestorFolderIDs(forSpaceWithID: id) {
                    return [folder.id] + ancestors
                }
            }
            return nil
        }
    }

    func containsFolder(withID id: UUID) -> Bool {
        switch self {
        case .space:
            return false
        case .folder(let folder):
            return folder.id == id
                || folder.children.contains { $0.containsFolder(withID: id) }
        }
    }

    func childNames(inFolderWithID id: UUID) -> [String]? {
        switch self {
        case .space:
            return nil
        case .folder(let folder):
            if folder.id == id {
                return folder.children.map(\.name)
            }
            return folder.children.lazy.compactMap { $0.childNames(inFolderWithID: id) }.first
        }
    }

    func siblingNames(forItemWithID id: UUID) -> [String]? {
        switch self {
        case .space:
            return nil
        case .folder(let folder):
            if folder.children.contains(where: { $0.id == id }) {
                return folder.children.filter { $0.id != id }.map(\.name)
            }
            return folder.children.lazy.compactMap { $0.siblingNames(forItemWithID: id) }.first
        }
    }

    mutating func updateSpace(
        withID id: UUID,
        update: (inout TerminalSpace) -> Void
    ) -> Bool {
        switch self {
        case .space(var space):
            guard space.id == id else {
                return false
            }
            update(&space)
            self = .space(space)
            return true

        case .folder(var folder):
            for index in folder.children.indices {
                if folder.children[index].updateSpace(withID: id, update: update) {
                    self = .folder(folder)
                    return true
                }
            }
            return false
        }
    }

    mutating func updateTerminal(
        withID id: UUID,
        title: String?,
        workingDirectory: String?
    ) -> Bool {
        switch self {
        case .space(var space):
            guard space.layout.terminalIDs.contains(id) else {
                return false
            }
            space.layout = space.layout.updatingTerminal(
                withID: id,
                title: title,
                workingDirectory: workingDirectory
            )
            self = .space(space)
            return true

        case .folder(var folder):
            for index in folder.children.indices {
                if folder.children[index].updateTerminal(
                    withID: id,
                    title: title,
                    workingDirectory: workingDirectory
                ) {
                    self = .folder(folder)
                    return true
                }
            }
            return false
        }
    }

    mutating func renameItem(withID id: UUID, to name: String) -> Bool {
        switch self {
        case .space(var space):
            guard space.id == id,
                space.name != name
            else {
                return false
            }
            space.name = name
            self = .space(space)
            return true

        case .folder(var folder):
            if folder.id == id {
                guard folder.name != name else {
                    return false
                }
                folder.name = name
                self = .folder(folder)
                return true
            }
            for index in folder.children.indices {
                if folder.children[index].renameItem(withID: id, to: name) {
                    self = .folder(folder)
                    return true
                }
            }
            return false
        }
    }

    mutating func removeDescendant(withID id: UUID) -> WorkspaceItem? {
        guard case .folder(var folder) = self else {
            return nil
        }

        if let index = folder.children.firstIndex(where: { $0.id == id }) {
            let removed = folder.children.remove(at: index)
            self = .folder(folder)
            return removed
        }

        for index in folder.children.indices {
            if let removed = folder.children[index].removeDescendant(withID: id) {
                self = .folder(folder)
                return removed
            }
        }
        return nil
    }

    mutating func append(_ item: WorkspaceItem, toFolderWithID folderID: UUID) -> Bool {
        switch self {
        case .space:
            return false
        case .folder(var folder):
            if folder.id == folderID {
                folder.children.append(item)
                self = .folder(folder)
                return true
            }

            for index in folder.children.indices {
                if folder.children[index].append(item, toFolderWithID: folderID) {
                    self = .folder(folder)
                    return true
                }
            }
            return false
        }
    }
}

enum WorkspaceSectionKind: String, Codable {
    case project
    case folder
}

struct TerminalProject: Codable, Equatable, Identifiable {
    let id: UUID
    var kind: WorkspaceSectionKind
    var name: String
    var rootDirectory: String
    var items: [WorkspaceItem]
    var lastSelectedSpaceID: UUID?

    init(
        id: UUID = UUID(),
        kind: WorkspaceSectionKind = .project,
        name: String,
        rootDirectory: String,
        items: [WorkspaceItem] = [],
        lastSelectedSpaceID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.rootDirectory = rootDirectory
        self.items = items
        self.lastSelectedSpaceID = lastSelectedSpaceID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case rootDirectory
        case items
        case lastSelectedSpaceID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(WorkspaceSectionKind.self, forKey: .kind) ?? .project
        name = try container.decode(String.self, forKey: .name)
        rootDirectory = try container.decode(String.self, forKey: .rootDirectory)
        items = try container.decode([WorkspaceItem].self, forKey: .items)
        lastSelectedSpaceID = try container.decodeIfPresent(UUID.self, forKey: .lastSelectedSpaceID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(rootDirectory, forKey: .rootDirectory)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(lastSelectedSpaceID, forKey: .lastSelectedSpaceID)
    }

    var firstSpace: TerminalSpace? {
        items.lazy.compactMap(\.firstSpace).first
    }

    var terminalIDs: Set<UUID> {
        items.reduce(into: Set<UUID>()) { ids, item in
            ids.formUnion(item.terminalIDs)
        }
    }

    var terminalSpaces: [TerminalSpace] {
        items.flatMap(\.terminalSpaces)
    }

    var folderIDs: Set<UUID> {
        items.reduce(into: Set<UUID>()) { ids, item in
            ids.formUnion(item.folderIDs)
        }
    }

    var preferredSpace: TerminalSpace? {
        if let lastSelectedSpaceID,
            let space = space(withID: lastSelectedSpaceID)
        {
            return space
        }
        return firstSpace
    }

    func space(withID id: UUID) -> TerminalSpace? {
        items.lazy.compactMap { $0.space(withID: id) }.first
    }

    func terminal(withID id: UUID) -> TerminalPane? {
        items.lazy.compactMap { $0.terminal(withID: id) }.first
    }

    func ancestorFolderIDs(forSpaceWithID id: UUID) -> [UUID] {
        items.lazy.compactMap { $0.ancestorFolderIDs(forSpaceWithID: id) }.first ?? []
    }

    func containsFolder(withID id: UUID) -> Bool {
        items.contains { $0.containsFolder(withID: id) }
    }

    func childNames(inFolderWithID id: UUID?) -> [String]? {
        guard let id else {
            return items.map(\.name)
        }
        return items.lazy.compactMap { $0.childNames(inFolderWithID: id) }.first
    }

    func siblingNames(forItemWithID id: UUID) -> [String]? {
        if items.contains(where: { $0.id == id }) {
            return items.filter { $0.id != id }.map(\.name)
        }
        return items.lazy.compactMap { $0.siblingNames(forItemWithID: id) }.first
    }

    mutating func updateSpace(
        withID id: UUID,
        update: (inout TerminalSpace) -> Void
    ) -> Bool {
        for index in items.indices {
            if items[index].updateSpace(withID: id, update: update) {
                return true
            }
        }
        return false
    }

    mutating func updateTerminal(
        withID id: UUID,
        title: String?,
        workingDirectory: String?
    ) -> Bool {
        for index in items.indices {
            if items[index].updateTerminal(
                withID: id,
                title: title,
                workingDirectory: workingDirectory
            ) {
                return true
            }
        }
        return false
    }

    mutating func renameItem(withID id: UUID, to name: String) -> Bool {
        for index in items.indices {
            if items[index].renameItem(withID: id, to: name) {
                return true
            }
        }
        return false
    }

    mutating func removeItem(withID id: UUID) -> WorkspaceItem? {
        if let index = items.firstIndex(where: { $0.id == id }) {
            return items.remove(at: index)
        }

        for index in items.indices {
            if let removed = items[index].removeDescendant(withID: id) {
                return removed
            }
        }
        return nil
    }

    mutating func append(_ item: WorkspaceItem, toFolderWithID folderID: UUID?) -> Bool {
        guard let folderID else {
            items.append(item)
            return true
        }

        for index in items.indices {
            if items[index].append(item, toFolderWithID: folderID) {
                return true
            }
        }
        return false
    }
}

struct WorkspaceDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [TerminalProject]
    var selectedProjectID: UUID?
    var selectedSpaceID: UUID?

    init(
        schemaVersion: Int = currentSchemaVersion,
        projects: [TerminalProject] = [],
        selectedProjectID: UUID? = nil,
        selectedSpaceID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.selectedProjectID = selectedProjectID
        self.selectedSpaceID = selectedSpaceID
    }

    var selectedProject: TerminalProject? {
        guard let selectedProjectID else {
            return nil
        }
        return projects.first { $0.id == selectedProjectID }
    }

    var terminalIDs: Set<UUID> {
        projects.reduce(into: Set<UUID>()) { ids, project in
            ids.formUnion(project.terminalIDs)
        }
    }

    var folderIDs: Set<UUID> {
        projects.reduce(into: Set<UUID>()) { ids, project in
            ids.formUnion(project.folderIDs)
        }
    }

    var selectedSpace: TerminalSpace? {
        guard let selectedSpaceID else {
            return nil
        }
        return selectedProject?.space(withID: selectedSpaceID)
    }

    func terminal(withID id: UUID) -> TerminalPane? {
        projects.lazy.compactMap { $0.terminal(withID: id) }.first
    }

    func project(containingTerminalWithID id: UUID) -> TerminalProject? {
        projects.first { $0.terminalIDs.contains(id) }
    }

    mutating func updateTerminal(
        withID id: UUID,
        title: String?,
        workingDirectory: String?
    ) -> Bool {
        for index in projects.indices {
            if projects[index].updateTerminal(
                withID: id,
                title: title,
                workingDirectory: workingDirectory
            ) {
                return true
            }
        }
        return false
    }
}
