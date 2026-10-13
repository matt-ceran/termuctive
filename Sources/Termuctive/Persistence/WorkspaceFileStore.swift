import Foundation

protocol WorkspacePersisting {
    var prefersBackgroundSaves: Bool { get }
    func load() throws -> WorkspaceDocument?
    func save(_ document: WorkspaceDocument) throws
    /// Copies a workspace that could not be loaded aside before it can be overwritten.
    func preserveUnreadableWorkspace() -> URL?
}

extension WorkspacePersisting {
    var prefersBackgroundSaves: Bool {
        false
    }

    func preserveUnreadableWorkspace() -> URL? {
        nil
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
        case 1, 2, 3, 4:
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

    func preserveUnreadableWorkspace() -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).unreadable-\(timestamp)")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
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
