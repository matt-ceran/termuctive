import Foundation

/// Where the editor's files live: this Mac, or a cloud server.
protocol EditorFileSystemProviding: Sendable {
    /// Remote files have no Finder location and are watched by polling.
    var isRemote: Bool { get }
    func buildTree(rootURL: URL) async throws -> EditorFileTreeSnapshot
    func read(_ url: URL) async throws -> EditorDiskSnapshot
    func readIfExists(_ url: URL) async throws -> EditorDiskSnapshot?
    /// Saves only when the file still matches `expectedSnapshot` (nil: the file must not
    /// exist), throwing `EditorDocumentError.changedOnDisk` otherwise.
    func write(
        text: String,
        to url: URL,
        encoding: EditorTextEncoding,
        lineEnding: EditorLineEnding,
        expectedSnapshot: EditorDiskSnapshot?
    ) async throws -> EditorDiskSnapshot
}

struct LocalEditorFileSystem: EditorFileSystemProviding {
    var isRemote: Bool {
        false
    }

    func buildTree(rootURL: URL) async throws -> EditorFileTreeSnapshot {
        let scan = Task.detached(priority: .utility) {
            try EditorFileTreeBuilder.build(rootURL: rootURL)
        }
        return try await withTaskCancellationHandler {
            try await scan.value
        } onCancel: {
            scan.cancel()
        }
    }

    func read(_ url: URL) async throws -> EditorDiskSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try EditorDiskIO.read(from: url)
        }.value
    }

    func readIfExists(_ url: URL) async throws -> EditorDiskSnapshot? {
        try await Task.detached(priority: .utility) {
            try EditorDiskIO.readIfExists(from: url)
        }.value
    }

    func write(
        text: String,
        to url: URL,
        encoding: EditorTextEncoding,
        lineEnding: EditorLineEnding,
        expectedSnapshot: EditorDiskSnapshot?
    ) async throws -> EditorDiskSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try EditorDiskIO.write(
                text: text,
                to: url,
                encoding: encoding,
                lineEnding: lineEnding,
                expectedSnapshot: expectedSnapshot
            )
        }.value
    }
}

extension EditorFileTreeSnapshot {
    /// Builds a navigator tree from root-relative paths, sorted like the local navigator.
    static func from(
        entries: [(path: String, isDirectory: Bool)],
        rootURL: URL,
        isTruncated: Bool
    ) -> EditorFileTreeSnapshot {
        var childrenByParent: [String: [(path: String, isDirectory: Bool)]] = [:]
        for entry in entries {
            let parent = (entry.path as NSString).deletingLastPathComponent
            childrenByParent[parent, default: []].append(entry)
        }

        func nodes(under parent: String) -> [EditorFileNode] {
            (childrenByParent[parent] ?? [])
                .sorted { left, right in
                    if left.isDirectory != right.isDirectory {
                        return left.isDirectory
                    }
                    return (left.path as NSString).lastPathComponent.localizedStandardCompare(
                        (right.path as NSString).lastPathComponent
                    ) == .orderedAscending
                }
                .map { entry in
                    EditorFileNode(
                        url: rootURL.appendingPathComponent(
                            entry.path, isDirectory: entry.isDirectory
                        )
                        .standardizedFileURL,
                        isDirectory: entry.isDirectory,
                        children: entry.isDirectory ? nodes(under: entry.path) : []
                    )
                }
        }

        return EditorFileTreeSnapshot(nodes: nodes(under: ""), isTruncated: isTruncated)
    }
}
