import Foundation

/// The editor's files on a cloud server, reached through the server toolkit.
///
/// Text is decoded and encoded on this Mac exactly as for local files; the server only
/// moves bytes and refuses a save when the file no longer has the expected digest.
struct RemoteEditorFileSystem: EditorFileSystemProviding {
    let runner: any CloudCommandRunning
    let alias: String

    var isRemote: Bool {
        true
    }

    private struct Tree: Decodable {
        let entries: [Entry]
        let truncated: Bool

        struct Entry: Decodable {
            let path: String
            let isDirectory: Bool

            init(from decoder: any Decoder) throws {
                var container = try decoder.unkeyedContainer()
                path = try container.decode(String.self)
                isDirectory = try container.decode(Bool.self)
            }
        }
    }

    private struct File: Decodable {
        let exists: Bool
        let isDirectory: Bool?
        let size: Int?
        let digest: String?
        let content: String?
    }

    private struct WriteResult: Decodable {
        let written: Bool?
        let conflict: Bool?
        let digest: String?
        let current: File?
    }

    func buildTree(rootURL: URL) async throws -> EditorFileTreeSnapshot {
        let tree = try await runner.decode(
            Tree.self,
            command(["fs", "tree", "--root", rootURL.standardizedFileURL.path], timeout: 120)
        )
        return EditorFileTreeSnapshot.from(
            entries: tree.entries.map { ($0.path, $0.isDirectory) },
            rootURL: rootURL.standardizedFileURL,
            isTruncated: tree.truncated
        )
    }

    func read(_ url: URL) async throws -> EditorDiskSnapshot {
        guard let snapshot = try await readIfExists(url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return snapshot
    }

    func readIfExists(_ url: URL) async throws -> EditorDiskSnapshot? {
        let file = try await runner.decode(
            File.self,
            command(["fs", "read", "--path", url.standardizedFileURL.path])
        )
        return try Self.snapshot(from: file)
    }

    func write(
        text: String,
        to url: URL,
        encoding: EditorTextEncoding,
        lineEnding: EditorLineEnding,
        expectedSnapshot: EditorDiskSnapshot?
    ) async throws -> EditorDiskSnapshot {
        let data = try EditorDiskIO.renderedData(
            text: text, encoding: encoding, lineEnding: lineEnding)
        let expected = expectedSnapshot.map { $0.contentDigest ?? "unknown" } ?? "absent"
        let result = try await runner.decode(
            WriteResult.self,
            CloudCommand(
                alias: alias,
                remote: .arguments([
                    TMCClient.executable, "fs", "write", "--path", url.standardizedFileURL.path,
                    "--expect", expected,
                ]),
                input: data,
                timeout: 60
            )
        )
        if result.conflict == true {
            let current = try? result.current.flatMap(Self.snapshot(from:))
            throw EditorDocumentError.changedOnDisk(current)
        }
        return try EditorDiskIO.snapshot(from: data)
    }

    private static func snapshot(from file: File) throws -> EditorDiskSnapshot? {
        guard file.exists else {
            return nil
        }
        if file.isDirectory == true {
            throw EditorDocumentError.directory
        }
        guard let content = file.content, let data = Data(base64Encoded: content) else {
            throw EditorDocumentError.fileTooLarge(file.size ?? EditorDiskIO.maximumFileSize + 1)
        }
        return try EditorDiskIO.snapshot(from: data)
    }

    private func command(_ arguments: [String], timeout: TimeInterval = 30) -> CloudCommand {
        CloudCommand(
            alias: alias, remote: .arguments([TMCClient.executable] + arguments), timeout: timeout)
    }
}
