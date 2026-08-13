import Foundation

protocol NotePersisting {
    func load(noteID: UUID) throws -> NoteDocument?
    func save(_ document: NoteDocument) throws
    func archive(noteID: UUID) throws
}

struct NoteFileStore: NotePersisting {
    let directoryURL: URL

    static var live: NoteFileStore {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return NoteFileStore(
            directoryURL:
                applicationSupport
                .appendingPathComponent("Termuctive", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
        )
    }

    func load(noteID: UUID) throws -> NoteDocument? {
        let url = fileURL(for: noteID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let document = try decoder.decode(NoteDocument.self, from: data)
        guard document.noteID == noteID else {
            throw NoteFileStoreError.mismatchedIdentifier
        }
        guard document.schemaVersion == NoteDocument.currentSchemaVersion else {
            throw NoteFileStoreError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    func save(_ document: NoteDocument) throws {
        guard document.schemaVersion == NoteDocument.currentSchemaVersion else {
            throw NoteFileStoreError.unsupportedSchema(document.schemaVersion)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(
            to: fileURL(for: document.noteID),
            options: .atomic
        )
    }

    func archive(noteID: UUID) throws {
        let sourceURL = fileURL(for: noteID)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }
        let archiveDirectory = directoryURL.appendingPathComponent(
            "Recently Deleted",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = archiveDirectory.appendingPathComponent(
            "\(noteID.uuidString)-\(UUID().uuidString).json"
        )
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func fileURL(for noteID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(noteID.uuidString).json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum NoteFileStoreError: LocalizedError {
    case mismatchedIdentifier
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .mismatchedIdentifier:
            "The saved note identifier does not match its file."
        case .unsupportedSchema(let version):
            "The saved note uses unsupported schema version \(version)."
        }
    }
}
