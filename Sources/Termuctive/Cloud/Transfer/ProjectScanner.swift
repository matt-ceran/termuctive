import Foundation

/// Builds the list of everything that moves with a project, without changing anything.
struct ProjectScanner {
    var git = GitInspector()
    var claude = ClaudeLocalData()
    var homeDirectory = NSHomeDirectory()
    var sizer: @Sendable (String, [String]) async -> Int64 = { path, excludes in
        await DiskUsage.bytes(at: path, excluding: excludes)
    }

    func scan(
        projectID: UUID,
        projectName: String,
        root: String,
        paneDirectories: [String],
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> TransferManifest {
        await progress("Reading git worktrees")
        // Git reports fully resolved paths, but the project keeps the spelling it was opened
        // with; the server mirrors that spelling, so git's paths are mapped back onto it.
        let gitRoot = await git.repositoryRoot(containing: root) ?? root
        let repositoryRoot = Self.realPath(root) == gitRoot ? root : gitRoot
        let spell = { (path: String) -> String in
            Self.respelled(path, resolvedRoot: gitRoot, as: repositoryRoot)
        }
        let worktrees = ((try? await git.worktrees(of: gitRoot)) ?? []).map { worktree in
            GitWorktree(
                path: spell(worktree.path),
                branch: worktree.branch,
                head: worktree.head,
                isMain: worktree.isMain,
                isLocked: worktree.isLocked,
                lastActivity: worktree.lastActivity
            )
        }
        let linked = worktrees.filter { !$0.isMain && $0.path != repositoryRoot }
        let insideProject = linked.filter { $0.path.hasPrefix(repositoryRoot + "/") }

        let now = Date()
        var items: [TransferItem] = []
        let existing = linked.filter { FileManager.default.fileExists(atPath: $0.path) }
        await progress("Measuring \(existing.count) worktrees")
        let worktreeSizes = await measure(existing.map(\.path))
        for worktree in existing {
            items.append(
                TransferItem(
                    id: "worktree:\(worktree.path)",
                    kind: .worktree,
                    title: URL(fileURLWithPath: worktree.path).lastPathComponent,
                    detail: Self.worktreeDetail(worktree, now: now),
                    localPath: worktree.path,
                    remotePath: worktree.path,
                    isDirectory: true,
                    bytes: worktreeSizes[worktree.path] ?? 0,
                    selected: true,
                    excludes: TransferDefaults.cacheExcludes,
                    lastActivity: worktree.lastActivity
                )
            )
        }

        await progress("Finding large folders")
        var largeFolders: [(path: String, bytes: Int64)] = []
        for entry in await git.ignoredEntries(in: repositoryRoot) where entry.hasSuffix("/") {
            let path = repositoryRoot + "/" + entry.dropLast()
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard !TransferDefaults.cacheExcludes.contains(name), worktreeSizes[path] == nil
            else {
                continue
            }
            let nested = worktreeSizes.filter { $0.key.hasPrefix(path + "/") }
            let bytes =
                await sizer(path, TransferDefaults.cacheExcludes)
                - nested.values.reduce(0, +)
            if bytes >= TransferDefaults.largeFolderThreshold {
                largeFolders.append((path, max(0, bytes)))
                items.append(
                    TransferItem(
                        id: "large:\(path)",
                        kind: .largeFolder,
                        title: relative(path, to: repositoryRoot),
                        detail: "Large ignored folder",
                        localPath: path,
                        remotePath: path,
                        isDirectory: true,
                        bytes: max(0, bytes),
                        selected: true,
                        excludes: TransferDefaults.cacheExcludes
                            + nested.keys.sorted().map { "/" + relative($0, to: path) },
                        lastActivity: nil
                    )
                )
            }
        }

        await progress("Measuring the project")
        let insideWorktrees = insideProject.map(\.path).filter { worktreeSizes[$0] != nil }
        let separatelyCopied =
            largeFolders.map(\.bytes).reduce(0, +)
            + insideWorktrees.compactMap { worktreeSizes[$0] }.reduce(0, +)
        let projectExcludes =
            TransferDefaults.cacheExcludes
            + (largeFolders.map(\.path) + insideWorktrees).sorted()
            .map { "/" + relative($0, to: repositoryRoot) }
        items.insert(
            TransferItem(
                id: "project:\(repositoryRoot)",
                kind: .project,
                title: projectName,
                detail: "Code, git history, .env files and local-only folders",
                localPath: repositoryRoot,
                remotePath: repositoryRoot,
                isDirectory: true,
                bytes: max(
                    0,
                    await sizer(repositoryRoot, TransferDefaults.cacheExcludes) - separatelyCopied
                ),
                selected: true,
                excludes: projectExcludes,
                lastActivity: nil
            ),
            at: 0
        )

        await progress("Looking for Claude history")
        let checkoutRoots = [repositoryRoot] + linked.map(\.path)
        let historyDirectories = claude.projectDataDirectories(for: checkoutRoots)
        for directory in historyDirectories {
            items.append(
                TransferItem(
                    id: "claude-history:\(directory.path)",
                    kind: .claudeHistory,
                    title: "History for \(directory.lastPathComponent)",
                    detail: "Conversations and memory",
                    localPath: directory.path,
                    remotePath: directory.path,
                    isDirectory: true,
                    bytes: await sizer(directory.path, []),
                    selected: true,
                    excludes: [],
                    lastActivity: nil
                )
            )
        }

        await progress("Looking for related folders")
        let scanner = PathReferenceScanner(homeDirectory: homeDirectory)
        let ruleFiles = PathReferenceScanner.ruleFiles(
            inProject: URL(fileURLWithPath: repositoryRoot),
            claudeDirectories: historyDirectories
        )
        let related = scanner.referencedFolders(
            in: ruleFiles,
            excluding: checkoutRoots + [claude.claudeDirectory.path]
        )
        for folder in related {
            let container = relative(folder, to: homeDirectory).split(separator: "/").first
                .map(String.init)
            items.append(
                TransferItem(
                    id: "related:\(folder)",
                    kind: .relatedFolder,
                    title: "~/" + relative(folder, to: homeDirectory),
                    detail: "Mentioned in the project's rules or memories",
                    localPath: folder,
                    remotePath: folder,
                    isDirectory: true,
                    bytes: await sizer(folder, TransferDefaults.cacheExcludes),
                    selected: !TransferDefaults.unselectedContainers.contains(container ?? ""),
                    excludes: TransferDefaults.cacheExcludes,
                    lastActivity: nil
                )
            )
        }

        await progress("Collecting personal settings")
        items += await personalItems()

        // Worktrees with open panes must come along.
        for index in items.indices where items[index].kind == .worktree {
            let path = items[index].localPath
            if paneDirectories.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
                items[index].selected = true
            }
        }

        return TransferManifest(
            projectID: projectID,
            projectName: projectName,
            projectRoot: repositoryRoot,
            items: items
        )
    }

    /// Measures folders a few at a time; projects can have well over a hundred worktrees.
    private func measure(_ paths: [String]) async -> [String: Int64] {
        let sizer = self.sizer
        return await withTaskGroup(of: (String, Int64).self) { group in
            var results: [String: Int64] = [:]
            var pending = paths[...]
            for _ in 0..<min(6, pending.count) {
                let path = pending.removeFirst()
                group.addTask { (path, await sizer(path, TransferDefaults.cacheExcludes)) }
            }
            while let (path, bytes) = await group.next() {
                results[path] = bytes
                if let next = pending.popFirst() {
                    group.addTask { (next, await sizer(next, TransferDefaults.cacheExcludes)) }
                }
            }
            return results
        }
    }

    private func personalItems() async -> [TransferItem] {
        var items: [TransferItem] = []
        let fileManager = FileManager.default
        let claudeEntries = ClaudeLocalData.portableEntries.filter { name in
            fileManager.fileExists(atPath: claude.claudeDirectory.appendingPathComponent(name).path)
        }
        if !claudeEntries.isEmpty
            || fileManager.fileExists(
                atPath: claude.claudeDirectory.appendingPathComponent("settings.json").path
            )
        {
            var bytes: Int64 = 0
            for name in claudeEntries {
                bytes += await sizer(claude.claudeDirectory.appendingPathComponent(name).path, [])
            }
            items.append(
                TransferItem(
                    id: "claude-configuration",
                    kind: .claudeConfiguration,
                    title: "Claude settings, skills and plugins",
                    detail: (["settings.json"] + claudeEntries).joined(separator: ", "),
                    localPath: claude.claudeDirectory.path,
                    remotePath: claude.claudeDirectory.path,
                    isDirectory: true,
                    bytes: bytes,
                    selected: true,
                    excludes: [],
                    lastActivity: nil
                )
            )
        }

        let personal: [(String, String, String)] = [
            (".aws", "AWS credentials and profiles", "folder"),
            (".gitconfig", "Git identity and settings", "file"),
            (".npmrc", "npm settings", "file"),
            (".config/gh", "GitHub CLI sign-in", "folder"),
        ]
        for (relativePath, title, type) in personal {
            let path = homeDirectory + "/" + relativePath
            guard fileManager.fileExists(atPath: path) else {
                continue
            }
            items.append(
                TransferItem(
                    id: "personal:\(path)",
                    kind: type == "folder" ? .personalFolder : .personalFile,
                    title: title,
                    detail: "~/" + relativePath,
                    localPath: path,
                    remotePath: path,
                    isDirectory: type == "folder",
                    bytes: await sizer(path, []),
                    selected: true,
                    excludes: [],
                    lastActivity: nil
                )
            )
        }
        return items
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer {
            free(resolved)
        }
        return String(cString: resolved)
    }

    static func respelled(_ path: String, resolvedRoot: String, as root: String) -> String {
        guard resolvedRoot != root else {
            return path
        }
        if path == resolvedRoot {
            return root
        }
        if path.hasPrefix(resolvedRoot + "/") {
            return root + path.dropFirst(resolvedRoot.count)
        }
        return path
    }

    private func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    static func worktreeDetail(_ worktree: GitWorktree, now: Date) -> String {
        var parts: [String] = []
        if let branch = worktree.branch {
            parts.append(branch)
        } else if let head = worktree.head {
            parts.append("detached at \(head.prefix(8))")
        }
        if let lastActivity = worktree.lastActivity {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("used " + formatter.localizedString(for: lastActivity, relativeTo: now))
        }
        return parts.joined(separator: " · ")
    }
}

enum DiskUsage {
    /// Allocated size of a file or folder, skipping folders with the given names anywhere.
    static func bytes(at path: String, excluding names: [String]) async -> Int64 {
        var arguments = ["-sk"]
        for name in names {
            arguments += ["-I", name]
        }
        arguments.append(path)
        guard let result = try? await ProcessRunner.run("/usr/bin/du", arguments, timeout: 900)
        else {
            return 0
        }
        let kilobytes =
            result.outputText.split(whereSeparator: \.isWhitespace).first
            .flatMap { Int64($0) } ?? 0
        return kilobytes * 1024
    }
}
