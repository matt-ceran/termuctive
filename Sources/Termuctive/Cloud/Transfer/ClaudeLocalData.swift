import Foundation

/// Claude Code's files on this Mac that belong with a project being moved.
struct ClaudeLocalData {
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    var claudeDirectory: URL {
        homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    var projectsDirectory: URL {
        claudeDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    var globalConfigURL: URL {
        homeDirectory.appendingPathComponent(".claude.json")
    }

    /// Personal Claude Code content that applies to every project.
    static let portableEntries = [
        "CLAUDE.md", "agents", "commands", "hooks", "keybindings.json", "output-styles",
        "plugins", "rules", "skills",
    ]

    /// Claude Code names a project's history folder after its path, replacing every
    /// character other than letters and digits with a hyphen.
    static func projectKey(for path: String) -> String {
        String(
            path.unicodeScalars.map { scalar -> Character in
                scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
                    ? Character(scalar) : "-"
            })
    }

    /// History folders for sessions whose working directory lies inside one of `roots`.
    ///
    /// Folder names are ambiguous (`bluekite-old` and `bluekite/old` share a key), so a
    /// candidate is confirmed by reading the working directory recorded in its transcripts.
    func projectDataDirectories(for roots: [String]) -> [URL] {
        let fileManager = FileManager.default
        guard
            let candidates = try? fileManager.contentsOfDirectory(
                at: projectsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        else {
            return []
        }
        let keys = roots.map(Self.projectKey(for:))
        return candidates.filter { candidate in
            let name = candidate.lastPathComponent
            guard keys.contains(where: { name == $0 || name.hasPrefix($0 + "-") }) else {
                return false
            }
            if keys.contains(name) {
                return true
            }
            guard let directory = recordedWorkingDirectory(in: candidate) else {
                return false
            }
            return roots.contains { root in
                directory == root || directory.hasPrefix(root + "/")
            }
        }
        // Keep the home folder's spelling rather than the resolved one FileManager returns.
        .map { projectsDirectory.appendingPathComponent($0.lastPathComponent, isDirectory: true) }
        .sorted { $0.path < $1.path }
    }

    func recordedWorkingDirectory(in directory: URL) -> String? {
        let fileManager = FileManager.default
        guard
            let transcripts = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
            .filter({ $0.pathExtension == "jsonl" })
        else {
            return nil
        }
        for transcript in transcripts.prefix(5) {
            guard let handle = try? FileHandle(forReadingFrom: transcript) else {
                continue
            }
            let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            try? handle.close()
            if let directory = Self.workingDirectory(inTranscriptPrefix: data) {
                return directory
            }
        }
        return nil
    }

    static func workingDirectory(inTranscriptPrefix data: Data) -> String? {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                let cwd = object["cwd"] as? String
            else {
                continue
            }
            return cwd
        }
        return nil
    }

    /// The parts of ~/.claude.json that describe these projects, plus user MCP servers.
    func globalConfigSubset(for roots: [String]) -> Data? {
        guard let data = try? Data(contentsOf: globalConfigURL),
            let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        var subset: [String: Any] = [:]
        if let projects = config["projects"] as? [String: Any] {
            subset["projects"] = projects.filter { path, _ in
                roots.contains { root in path == root || path.hasPrefix(root + "/") }
            }
        }
        if let servers = config["mcpServers"] as? [String: Any] {
            subset["mcpServers"] = servers
        }
        return try? JSONSerialization.data(withJSONObject: subset, options: [.sortedKeys])
    }
}
