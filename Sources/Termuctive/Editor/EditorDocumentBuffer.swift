import Foundation

enum EditorTextEncoding: String, Equatable, Sendable {
    case utf8
    case utf8WithByteOrderMark
    case utf16BigEndian
    case utf16LittleEndian

    var title: String {
        switch self {
        case .utf8:
            "UTF-8"
        case .utf8WithByteOrderMark:
            "UTF-8 BOM"
        case .utf16BigEndian:
            "UTF-16 BE"
        case .utf16LittleEndian:
            "UTF-16 LE"
        }
    }
}

enum EditorLineEnding: String, Equatable, Sendable {
    case lineFeed
    case carriageReturnLineFeed
    case carriageReturn

    var title: String {
        switch self {
        case .lineFeed:
            "LF"
        case .carriageReturnLineFeed:
            "CRLF"
        case .carriageReturn:
            "CR"
        }
    }

    var sequence: String {
        switch self {
        case .lineFeed:
            "\n"
        case .carriageReturnLineFeed:
            "\r\n"
        case .carriageReturn:
            "\r"
        }
    }
}

struct EditorDiskSnapshot: Equatable, Sendable {
    let text: String
    let encoding: EditorTextEncoding
    let lineEnding: EditorLineEnding
}

enum EditorExternalChange: Equatable, Sendable {
    case modified(EditorDiskSnapshot)
    case deleted
}

enum EditorDocumentError: LocalizedError {
    case binaryFile
    case changedOnDisk(EditorDiskSnapshot?)
    case directory
    case fileTooLarge(Int)
    case unreadableEncoding

    var errorDescription: String? {
        switch self {
        case .binaryFile:
            "This file appears to be binary and cannot be edited as source text."
        case .changedOnDisk:
            "The file changed on disk. Review the external change before saving."
        case .directory:
            "Choose a file instead of a directory."
        case .fileTooLarge(let byteCount):
            "This file is \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)). The editor limit is 5 MB."
        case .unreadableEncoding:
            "This file is not valid UTF-8 or UTF-16 text."
        }
    }
}

enum EditorDiskIO {
    static let maximumFileSize = 5 * 1_024 * 1_024

    static func read(from url: URL) throws -> EditorDiskSnapshot {
        let resourceValues = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
        ])
        guard resourceValues.isDirectory != true else {
            throw EditorDocumentError.directory
        }
        let fileSize = resourceValues.fileSize ?? 0
        guard fileSize <= maximumFileSize else {
            throw EditorDocumentError.fileTooLarge(fileSize)
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoded = try decode(data)
        let lineEnding = preferredLineEnding(in: decoded.text)
        return EditorDiskSnapshot(
            text: normalizeLineEndings(in: decoded.text),
            encoding: decoded.encoding,
            lineEnding: lineEnding
        )
    }

    static func readIfExists(from url: URL) throws -> EditorDiskSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try read(from: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func write(
        text: String,
        to url: URL,
        encoding: EditorTextEncoding,
        lineEnding: EditorLineEnding,
        expectedSnapshot: EditorDiskSnapshot?
    ) throws -> EditorDiskSnapshot {
        let currentSnapshot = try readIfExists(from: url)
        guard snapshotsMatch(currentSnapshot, expectedSnapshot) else {
            throw EditorDocumentError.changedOnDisk(currentSnapshot)
        }

        let normalizedText = normalizeLineEndings(in: text)
        let renderedText =
            lineEnding == .lineFeed
            ? normalizedText
            : normalizedText.replacingOccurrences(of: "\n", with: lineEnding.sequence)
        let data = try encodedData(for: renderedText, encoding: encoding)
        let fileManager = FileManager.default
        let parentURL = url.deletingLastPathComponent()
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(url.lastPathComponent).termuctive-\(UUID().uuidString).tmp"
        )
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try data.write(to: temporaryURL, options: .withoutOverwriting)
        if let permissions = attributes?[.posixPermissions] {
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: temporaryURL.path
            )
        }

        if currentSnapshot != nil {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        return EditorDiskSnapshot(
            text: normalizeLineEndings(in: renderedText),
            encoding: encoding,
            lineEnding: lineEnding
        )
    }

    private static func decode(_ data: Data) throws -> (text: String, encoding: EditorTextEncoding)
    {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw EditorDocumentError.unreadableEncoding
            }
            return (text, .utf8WithByteOrderMark)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            guard
                let text = String(
                    data: data.dropFirst(2),
                    encoding: .utf16LittleEndian
                )
            else {
                throw EditorDocumentError.unreadableEncoding
            }
            return (text, .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            guard
                let text = String(
                    data: data.dropFirst(2),
                    encoding: .utf16BigEndian
                )
            else {
                throw EditorDocumentError.unreadableEncoding
            }
            return (text, .utf16BigEndian)
        }
        guard !data.contains(0) else {
            throw EditorDocumentError.binaryFile
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EditorDocumentError.unreadableEncoding
        }
        return (text, .utf8)
    }

    private static func encodedData(
        for text: String,
        encoding: EditorTextEncoding
    ) throws -> Data {
        let encoded: Data?
        switch encoding {
        case .utf8:
            encoded = text.data(using: .utf8)
        case .utf8WithByteOrderMark:
            guard let body = text.data(using: .utf8) else {
                encoded = nil
                break
            }
            encoded = Data([0xEF, 0xBB, 0xBF]) + body
        case .utf16BigEndian:
            guard let body = text.data(using: .utf16BigEndian) else {
                encoded = nil
                break
            }
            encoded = Data([0xFE, 0xFF]) + body
        case .utf16LittleEndian:
            guard let body = text.data(using: .utf16LittleEndian) else {
                encoded = nil
                break
            }
            encoded = Data([0xFF, 0xFE]) + body
        }
        guard let encoded else {
            throw EditorDocumentError.unreadableEncoding
        }
        return encoded
    }

    private static func snapshotsMatch(
        _ left: EditorDiskSnapshot?,
        _ right: EditorDiskSnapshot?
    ) -> Bool {
        switch (left, right) {
        case (nil, nil):
            true
        case (.some(let left), .some(let right)):
            left.text == right.text
                && left.encoding == right.encoding
                && left.lineEnding == right.lineEnding
        default:
            false
        }
    }

    private static func preferredLineEnding(in text: String) -> EditorLineEnding {
        if text.contains("\r\n") {
            return .carriageReturnLineFeed
        }
        if text.contains("\n") {
            return .lineFeed
        }
        if text.contains("\r") {
            return .carriageReturn
        }
        return .lineFeed
    }

    private static func normalizeLineEndings(in text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

@MainActor
final class EditorDocumentBuffer: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL

    @Published private(set) var text: String
    @Published private(set) var externalChange: EditorExternalChange?
    @Published private(set) var isSaving = false
    @Published private(set) var cursorLine = 1
    @Published private(set) var cursorColumn = 1
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    private var baselineSnapshot: EditorDiskSnapshot?
    private var currentSaveTask: Task<Void, Error>?
    private var saveGeneration = 0
    private var refreshGeneration = 0
    private var statusGeneration = 0

    private init(url: URL, snapshot: EditorDiskSnapshot) {
        self.url = url.standardizedFileURL
        text = snapshot.text
        baselineSnapshot = snapshot
    }

    static func open(url: URL) async throws -> EditorDocumentBuffer {
        let standardizedURL = url.standardizedFileURL
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try EditorDiskIO.read(from: standardizedURL)
        }.value
        return EditorDocumentBuffer(url: standardizedURL, snapshot: snapshot)
    }

    var isDirty: Bool {
        text != baselineSnapshot?.text
    }

    var canSave: Bool {
        isDirty && externalChange == nil && !isSaving
    }

    var hasUncommittedChanges: Bool {
        isDirty || isSaving
    }

    var encodingTitle: String {
        baselineSnapshot?.encoding.title ?? "UTF-8"
    }

    var lineEndingTitle: String {
        baselineSnapshot?.lineEnding.title ?? "LF"
    }

    func updateText(_ updatedText: String) {
        guard text != updatedText else {
            return
        }
        text = updatedText
        errorMessage = nil
        statusMessage = nil
    }

    func updateCursor(line: Int, column: Int) {
        let resolvedLine = max(line, 1)
        let resolvedColumn = max(column, 1)
        guard cursorLine != resolvedLine || cursorColumn != resolvedColumn else {
            return
        }
        cursorLine = resolvedLine
        cursorColumn = resolvedColumn
    }

    func refreshFromDisk() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let fileURL = url
        let result = await Task.detached(priority: .utility) {
            Result {
                try EditorDiskIO.readIfExists(from: fileURL)
            }
        }.value
        guard refreshGeneration == generation else {
            return
        }
        switch result {
        case .success(let diskSnapshot):
            applyExternalSnapshot(diskSnapshot)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func save() async throws {
        if let currentSaveTask {
            try await currentSaveTask.value
            if isDirty {
                try await save()
            }
            return
        }
        guard isDirty else {
            return
        }
        guard externalChange == nil else {
            throw EditorDocumentError.changedOnDisk(externalSnapshot)
        }

        saveGeneration &+= 1
        let generation = saveGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                if saveGeneration == generation {
                    currentSaveTask = nil
                }
            }
            try await performSave()
        }
        currentSaveTask = task
        try await task.value
    }

    private func performSave() async throws {
        isSaving = true
        errorMessage = nil
        refreshGeneration &+= 1
        defer {
            isSaving = false
        }

        let fileURL = url
        let localText = text
        let expectedSnapshot = baselineSnapshot
        let encoding = baselineSnapshot?.encoding ?? .utf8
        let lineEnding = baselineSnapshot?.lineEnding ?? .lineFeed
        do {
            let savedSnapshot = try await Task.detached(priority: .userInitiated) {
                try EditorDiskIO.write(
                    text: localText,
                    to: fileURL,
                    encoding: encoding,
                    lineEnding: lineEnding,
                    expectedSnapshot: expectedSnapshot
                )
            }.value
            baselineSnapshot = savedSnapshot
            if text == localText {
                text = savedSnapshot.text
            }
            showStatus(isDirty ? "Saved previous changes" : "Saved")
        } catch EditorDocumentError.changedOnDisk(let diskSnapshot) {
            externalChange = diskSnapshot.map(EditorExternalChange.modified) ?? .deleted
            errorMessage = EditorDocumentError.changedOnDisk(diskSnapshot).localizedDescription
            throw EditorDocumentError.changedOnDisk(diskSnapshot)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func reloadExternalVersion() {
        guard case .modified(let snapshot) = externalChange else {
            return
        }
        baselineSnapshot = snapshot
        text = snapshot.text
        externalChange = nil
        errorMessage = nil
        showStatus("Reloaded from disk")
    }

    func keepLocalVersion() {
        switch externalChange {
        case .modified(let snapshot):
            baselineSnapshot = snapshot
        case .deleted:
            baselineSnapshot = nil
        case nil:
            return
        }
        externalChange = nil
        errorMessage = nil
        showStatus("Keeping local edits")
    }

    private var externalSnapshot: EditorDiskSnapshot? {
        guard case .modified(let snapshot) = externalChange else {
            return nil
        }
        return snapshot
    }

    private func applyExternalSnapshot(_ diskSnapshot: EditorDiskSnapshot?) {
        guard diskSnapshot != baselineSnapshot else {
            if externalChange != nil {
                externalChange = nil
                errorMessage = nil
            }
            return
        }

        if let diskSnapshot, diskSnapshot.text == text {
            baselineSnapshot = diskSnapshot
            externalChange = nil
            errorMessage = nil
            return
        }

        if !isDirty {
            guard let diskSnapshot else {
                externalChange = .deleted
                errorMessage = "This file was deleted on disk."
                return
            }
            baselineSnapshot = diskSnapshot
            text = diskSnapshot.text
            externalChange = nil
            errorMessage = nil
            showStatus("Updated from disk")
            return
        }

        externalChange = diskSnapshot.map(EditorExternalChange.modified) ?? .deleted
        errorMessage = "This file changed on disk while it has unsaved edits."
    }

    private func showStatus(_ message: String) {
        statusGeneration &+= 1
        let generation = statusGeneration
        statusMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, statusGeneration == generation else {
                return
            }
            statusMessage = nil
        }
    }
}
