import CoreServices
import Foundation

struct EditorFileNode: Equatable, Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    let children: [EditorFileNode]

    var id: String {
        url.standardizedFileURL.path
    }

    var name: String {
        url.lastPathComponent
    }
}

struct EditorFileTreeSnapshot: Equatable, Sendable {
    let nodes: [EditorFileNode]
    let isTruncated: Bool
}

enum EditorFileTreeBuilder {
    static func build(
        rootURL: URL,
        maximumItemCount: Int = 50_000
    ) throws -> EditorFileTreeSnapshot {
        let root = rootURL.standardizedFileURL
        var remainingItemCount = max(maximumItemCount, 1)
        var isTruncated = false
        let nodes = try children(
            of: root,
            remainingItemCount: &remainingItemCount,
            isTruncated: &isTruncated
        )
        return EditorFileTreeSnapshot(nodes: nodes, isTruncated: isTruncated)
    }

    private static func children(
        of directory: URL,
        remainingItemCount: inout Int,
        isTruncated: inout Bool
    ) throws -> [EditorFileNode] {
        guard remainingItemCount > 0 else {
            isTruncated = true
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )

        var entries: [(url: URL, isDirectory: Bool, canTraverse: Bool)] = []
        entries.reserveCapacity(urls.count)
        for url in urls where url.lastPathComponent != ".DS_Store" {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let isDirectory = values?.isDirectory == true
            if isDirectory, ignoredDirectoryNames.contains(url.lastPathComponent) {
                continue
            }
            guard isDirectory || values?.isRegularFile == true || values?.isSymbolicLink == true
            else {
                continue
            }
            entries.append(
                (
                    url: url.standardizedFileURL,
                    isDirectory: isDirectory,
                    canTraverse: isDirectory
                        && values?.isSymbolicLink != true
                        && values?.isPackage != true
                )
            )
        }

        entries.sort { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.url.lastPathComponent.localizedStandardCompare(
                right.url.lastPathComponent
            ) == .orderedAscending
        }

        var nodes: [EditorFileNode] = []
        nodes.reserveCapacity(entries.count)
        for entry in entries {
            guard remainingItemCount > 0 else {
                isTruncated = true
                break
            }
            remainingItemCount -= 1
            let childNodes =
                entry.canTraverse
                ? (try? children(
                    of: entry.url,
                    remainingItemCount: &remainingItemCount,
                    isTruncated: &isTruncated
                )) ?? []
                : []
            nodes.append(
                EditorFileNode(
                    url: entry.url,
                    isDirectory: entry.isDirectory,
                    children: childNodes
                )
            )
        }
        return nodes
    }

    private static let ignoredDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".gradle",
        ".next",
        ".swiftpm",
        ".terraform",
        ".tox",
        ".venv",
        "DerivedData",
        "__pycache__",
        "build",
        "coverage",
        "dist",
        "node_modules",
        "Pods",
        "target",
        "vendor",
    ]
}

final class ProjectFileWatcher: @unchecked Sendable {
    private final class CallbackBox {
        let handler: @Sendable ([URL]) -> Void

        init(handler: @escaping @Sendable ([URL]) -> Void) {
            self.handler = handler
        }
    }

    private let callbackBox: CallbackBox
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    init?(
        rootURL: URL,
        latency: TimeInterval = 0.15,
        handler: @escaping @Sendable ([URL]) -> Void
    ) {
        callbackBox = CallbackBox(handler: handler)
        queue = DispatchQueue(
            label: "com.mattceran.termuctive.editor-file-watcher",
            qos: .utility
        )

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = {
            _, callbackInfo, eventCount, eventPaths, _, _ in
            guard let callbackInfo else {
                return
            }
            let box = Unmanaged<CallbackBox>.fromOpaque(callbackInfo).takeUnretainedValue()
            let rawPaths = unsafeBitCast(eventPaths, to: NSArray.self)
            let paths = rawPaths.compactMap { value -> URL? in
                guard let path = value as? String else {
                    return nil
                }
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            if !paths.isEmpty || eventCount > 0 {
                box.handler(paths)
            }
        }
        let flags =
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [rootURL.standardizedFileURL.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                max(latency, 0.05),
                flags
            )
        else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
