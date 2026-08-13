import Foundation

protocol WorkspacePersisting {
    var prefersBackgroundSaves: Bool { get }
    func load() throws -> WorkspaceDocument?
    func save(_ document: WorkspaceDocument) throws
}

extension WorkspacePersisting {
    var prefersBackgroundSaves: Bool {
        false
    }
}

struct WorkspaceFileStore: WorkspacePersisting {
    let fileURL: URL

    var prefersBackgroundSaves: Bool {
        true
    }

    static var live: WorkspaceFileStore {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return WorkspaceFileStore(
            fileURL:
                applicationSupport
                .appendingPathComponent("Termuctive", isDirectory: true)
                .appendingPathComponent("workspace.json")
        )
    }

    func load() throws -> WorkspaceDocument? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        var document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        switch document.schemaVersion {
        case 1, 2, 3:
            document.schemaVersion = WorkspaceDocument.currentSchemaVersion
        case WorkspaceDocument.currentSchemaVersion:
            break
        default:
            throw WorkspaceFileStoreError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    func save(_ document: WorkspaceDocument) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }
}

enum WorkspaceFileStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "The saved workspace uses unsupported schema version \(version)."
        }
    }
}
