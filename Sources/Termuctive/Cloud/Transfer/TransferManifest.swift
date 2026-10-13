import Foundation

/// One thing copied to the server when a project moves.
struct TransferItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// The project folder, without its worktrees and very large ignored folders.
        case project
        case worktree
        /// A large ignored folder inside the project, such as archives.
        case largeFolder
        /// A folder outside the project that its rules or memories refer to.
        case relatedFolder
        case claudeHistory
        case claudeConfiguration
        case personalFolder
        case personalFile
    }

    enum Group: String, Codable, CaseIterable {
        case project
        case related
        case claude
        case personal

        var title: String {
            switch self {
            case .project:
                "Project and worktrees"
            case .related:
                "Related folders"
            case .claude:
                "Claude history, memory and settings"
            case .personal:
                "Personal settings and credentials"
            }
        }
    }

    let id: String
    var kind: Kind
    var title: String
    var detail: String?
    /// Absolute path on this Mac.
    var localPath: String
    /// Absolute path on the server. Matches `localPath`, because member homes mirror the Mac.
    var remotePath: String
    var isDirectory: Bool
    var bytes: Int64
    var selected: Bool
    /// Paths relative to `localPath` that are copied separately or not at all.
    var excludes: [String]
    var lastActivity: Date?

    var group: Group {
        switch kind {
        case .project, .worktree, .largeFolder:
            .project
        case .relatedFolder:
            .related
        case .claudeHistory, .claudeConfiguration:
            .claude
        case .personalFolder, .personalFile:
            .personal
        }
    }

    /// Order of copying: small configuration first so the server is usable early.
    var order: Int {
        switch kind {
        case .personalFile, .personalFolder, .claudeConfiguration:
            0
        case .project:
            1
        case .worktree:
            2
        case .claudeHistory:
            3
        case .relatedFolder:
            4
        case .largeFolder:
            5
        }
    }

    /// Whether a final pass may delete server files that no longer exist on the Mac.
    var mirrorsDeletions: Bool {
        switch kind {
        case .project, .worktree:
            true
        default:
            false
        }
    }
}

struct TransferManifest: Codable, Equatable {
    var projectID: UUID
    var projectName: String
    var projectRoot: String
    var items: [TransferItem]

    var selectedItems: [TransferItem] {
        items.filter(\.selected).sorted { ($0.order, $0.localPath) < ($1.order, $1.localPath) }
    }

    var selectedBytes: Int64 {
        items.filter(\.selected).reduce(0) { $0 + $1.bytes }
    }

    func items(in group: TransferItem.Group) -> [TransferItem] {
        items.filter { $0.group == group }
    }

    /// Checkout paths whose Claude history and settings belong with the project.
    var checkoutRoots: [String] {
        items.filter { $0.kind == .project || $0.kind == .worktree }.map(\.localPath)
    }
}

enum TransferDefaults {
    /// Dependency and build caches hold platform-specific files and are rebuilt on the server.
    static let cacheExcludes = [
        "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", ".next", ".turbo", ".vite", ".parcel-cache", ".DS_Store",
    ]
    /// Ignored folders larger than this are listed separately so they can be skipped.
    static let largeFolderThreshold: Int64 = 500 * 1024 * 1024
    /// Worktrees edited within this window may get their dependencies installed on the server.
    static let hydrateWindow: TimeInterval = 24 * 60 * 60
    /// At most this many recently used worktrees are prepared automatically after a move.
    static let hydrateRecentLimit = 3
    /// Home folders whose referenced subfolders are offered but not selected by default.
    static let unselectedContainers: Set<String> = ["Downloads", "Desktop"]
}
