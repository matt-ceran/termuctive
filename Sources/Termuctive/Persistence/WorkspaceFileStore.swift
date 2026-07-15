import Foundation

protocol WorkspacePersisting {
    func load() throws -> WorkspaceDocument?
    func save(_ document: WorkspaceDocument) throws
}

struct WorkspaceFileStore: WorkspacePersisting {
    let fileURL: URL

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
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        guard document.schemaVersion == WorkspaceDocument.currentSchemaVersion else {
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
