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

    func space(withID id: UUID) -> TerminalSpace? {
        switch self {
        case .space(let space):
            space.id == id ? space : nil
        case .folder(let folder):
            folder.children.lazy.compactMap { $0.space(withID: id) }.first
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

struct TerminalProject: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var rootDirectory: String
    var items: [WorkspaceItem]

    init(
        id: UUID = UUID(),
        name: String,
        rootDirectory: String,
        items: [WorkspaceItem] = []
    ) {
        self.id = id
        self.name = name
        self.rootDirectory = rootDirectory
        self.items = items
    }

    var firstSpace: TerminalSpace? {
        items.lazy.compactMap(\.firstSpace).first
    }

    func space(withID id: UUID) -> TerminalSpace? {
        items.lazy.compactMap { $0.space(withID: id) }.first
    }

    func containsFolder(withID id: UUID) -> Bool {
        items.contains { $0.containsFolder(withID: id) }
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

    var selectedSpace: TerminalSpace? {
        guard let selectedSpaceID else {
            return nil
        }
        return selectedProject?.space(withID: selectedSpaceID)
    }
}
