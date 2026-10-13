import Foundation

/// Finds folders outside a project that its agent rules and memories point at, such as
/// a data folder referenced as `~/model-data`, so they can move with the project.
struct PathReferenceScanner {
    let homeDirectory: String

    /// Home folders that hold many unrelated things; references inside them name the
    /// next path component instead (for example ~/Documents/telesales).
    static let containerFolders: Set<String> = [
        "Documents", "Desktop", "Downloads", "Developer", "Projects", "code", "src", "work",
        "repos", "dev",
    ]
    static let ignoredFolders: Set<String> = [
        ".claude", ".ssh", ".Trash", "Library", "Applications", "Movies", "Music", "Pictures",
        "Public",
    ]

    init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    /// Text files worth scanning: agent rules, memories and Claude settings.
    static func ruleFiles(inProject root: URL, claudeDirectories: [URL]) -> [URL] {
        var files: [URL] = []
        let fileManager = FileManager.default
        for name in ["CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".mcp.json"] {
            let url = root.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                files.append(url)
            }
        }
        for folder in [
            root.appendingPathComponent("memory"), root.appendingPathComponent(".claude"),
        ]
            + claudeDirectories.map({ $0.appendingPathComponent("memory") })
        {
            guard
                let enumerator = fileManager.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
                )
            else {
                continue
            }
            for case let url as URL in enumerator
            where ["md", "json", "tsv", "txt"].contains(url.pathExtension)
                && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 2_000_000
            {
                files.append(url)
            }
        }
        return files
    }

    func referencedFolders(in files: [URL], excluding projectRoots: [String]) -> [String] {
        var found = Set<String>()
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            found.formUnion(referencedFolders(inText: text))
        }
        return
            found
            .filter { folder in
                !projectRoots.contains { root in
                    folder == root || folder.hasPrefix(root + "/") || root.hasPrefix(folder + "/")
                }
            }
            .filter { folder in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted()
    }

    func referencedFolders(inText text: String) -> Set<String> {
        let escapedHome = NSRegularExpression.escapedPattern(for: homeDirectory)
        let pattern = "(?:~|\\$HOME|\(escapedHome))/([A-Za-z0-9._-]+)(?:/([A-Za-z0-9._ -]+))?"
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        var folders = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: range) {
            guard let firstRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let first = Self.trimmingTrailingPunctuation(String(text[firstRange]))
            // Hidden folders hold per-machine tools and settings (~/.local holds macOS
            // binaries); the portable ones are copied separately as personal settings.
            if first.isEmpty || first.hasPrefix(".") || Self.ignoredFolders.contains(first) {
                continue
            }
            if Self.containerFolders.contains(first) {
                guard let secondRange = Range(match.range(at: 2), in: text) else {
                    continue
                }
                let second = Self.trimmingTrailingPunctuation(
                    String(text[secondRange]).trimmingCharacters(in: .whitespaces)
                )
                if !second.isEmpty {
                    folders.insert("\(homeDirectory)/\(first)/\(second)")
                }
            } else {
                folders.insert("\(homeDirectory)/\(first)")
            }
        }
        return folders
    }

    /// Paths written at the end of a sentence pick up its punctuation.
    static func trimmingTrailingPunctuation(_ component: String) -> String {
        var trimmed = component
        while let last = trimmed.last, ".,;:".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }
}
