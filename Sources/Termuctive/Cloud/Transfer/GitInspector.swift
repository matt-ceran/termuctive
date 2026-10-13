import Foundation

struct GitWorktree: Equatable {
    let path: String
    let branch: String?
    let head: String?
    let isMain: Bool
    let isLocked: Bool
    /// When git last touched this checkout's index or HEAD.
    let lastActivity: Date?
}

/// Read-only questions about a local git repository, answered with the git command line.
struct GitInspector {
    var gitExecutable = "/usr/bin/git"

    func repositoryRoot(containing path: String) async -> String? {
        let result = try? await git(["-C", path, "rev-parse", "--show-toplevel"])
        return result.flatMap { $0.isEmpty ? nil : $0 }
    }

    func commonDirectory(of root: String) async -> String? {
        guard let value = try? await git(["-C", root, "rev-parse", "--git-common-dir"]),
            !value.isEmpty
        else {
            return nil
        }
        return value.hasPrefix("/")
            ? value
            : URL(fileURLWithPath: root).appendingPathComponent(value).standardizedFileURL.path
    }

    func worktrees(of root: String) async throws -> [GitWorktree] {
        let output = try await git(["-C", root, "worktree", "list", "--porcelain"])
        return Self.parseWorktrees(output).map { entry in
            GitWorktree(
                path: entry.path,
                branch: entry.branch,
                head: entry.head,
                isMain: entry.isMain,
                isLocked: entry.isLocked,
                lastActivity: Self.lastActivity(ofWorktreeAt: entry.path)
            )
        }
    }

    func remoteURL(of root: String) async -> String? {
        try? await git(["-C", root, "remote", "get-url", "origin"])
    }

    /// Ignored entries directly inside a checkout, folders reported once with a trailing slash.
    func ignoredEntries(in root: String) async -> [String] {
        guard
            let output = try? await git(
                [
                    "-C", root, "ls-files", "--others", "--ignored", "--exclude-standard",
                    "--directory",
                ]
            )
        else {
            return []
        }
        return output.split(separator: "\n").map(String.init)
    }

    private func git(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(gitExecutable, arguments, timeout: 120)
        guard result.succeeded else {
            throw CloudCommandError.failed(
                command: "git \(arguments.joined(separator: " "))",
                status: result.status,
                message: result.errorText
            )
        }
        return result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct PorcelainEntry: Equatable {
        var path: String
        var head: String?
        var branch: String?
        var isMain: Bool
        var isLocked: Bool
    }

    static func parseWorktrees(_ porcelain: String) -> [PorcelainEntry] {
        var entries: [PorcelainEntry] = []
        var current: PorcelainEntry?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current {
                    entries.append(current)
                }
                current = PorcelainEntry(
                    path: String(line.dropFirst("worktree ".count)),
                    isMain: entries.isEmpty,
                    isLocked: false
                )
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.isLocked = true
            }
        }
        if let current {
            entries.append(current)
        }
        return entries
    }

    static func lastActivity(ofWorktreeAt path: String) -> Date? {
        let fileManager = FileManager.default
        let gitPath = URL(fileURLWithPath: path).appendingPathComponent(".git")
        var gitDirectory = gitPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitPath.path, isDirectory: &isDirectory) else {
            return nil
        }
        if !isDirectory.boolValue,
            let pointer = try? String(contentsOf: gitPath, encoding: .utf8),
            let line = pointer.split(separator: "\n").first,
            line.hasPrefix("gitdir: ")
        {
            let target = String(line.dropFirst("gitdir: ".count))
            gitDirectory =
                target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : URL(fileURLWithPath: path).appendingPathComponent(target).standardizedFileURL
        }
        return ["index", "logs/HEAD", "HEAD"]
            .compactMap { name in
                try? fileManager.attributesOfItem(
                    atPath: gitDirectory.appendingPathComponent(name).path
                )[.modificationDate] as? Date
            }
            .max()
    }
}
