import Foundation

/// Brings a collaborator's own local copy of the project into the shared cloud project:
/// their branches, their checkouts (with uncommitted work and .env files) as worktrees
/// named after them, their Claude history and memories, and their personal settings.
@MainActor
final class PartnerImport: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case finished
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var notes: [String] = []
    @Published private(set) var createdWorktrees: [String] = []
    /// Whether the collaborator's Claude and git settings are copied too.
    var includesSettings = true

    let localRoot: String
    private let binding: CloudProjectBinding
    private let host: CloudHost
    private let cloud: CloudSessionCoordinator
    private let git: GitInspector
    private let claude: ClaudeLocalData

    init(
        localRoot: String,
        binding: CloudProjectBinding,
        host: CloudHost,
        cloud: CloudSessionCoordinator,
        git: GitInspector = GitInspector(),
        claude: ClaudeLocalData = ClaudeLocalData()
    ) {
        self.localRoot = localRoot
        self.binding = binding
        self.host = host
        self.cloud = cloud
        self.git = git
        self.claude = claude
    }

    func run() async {
        notes = []
        createdWorktrees = []
        do {
            state = .working("Reading your local checkouts")
            guard let repositoryRoot = await git.repositoryRoot(containing: localRoot) else {
                throw CloudCommandError.invalidResponse("\(localRoot) is not a git repository.")
            }
            let checkouts = try await git.worktrees(of: repositoryRoot)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            await cloud.control.ensureMaster(alias: host.alias)
            let status = try await cloud.client.status(alias: host.alias)

            state = .working("Sending your branches")
            try await pushBranches(from: repositoryRoot)
            let mapping = try await cloud.runner.decode(
                [String: String].self,
                command([TMCClient.executable, "import-refs", "--root", binding.remoteRoot])
            )
            let renamed = mapping.filter { $0.key != $0.value }
            if !renamed.isEmpty {
                notes.append(
                    "Branches that already existed differently were kept as "
                        + renamed.values.sorted().joined(separator: ", ") + "."
                )
            }

            let engine = settingsEngine()
            for (index, checkout) in checkouts.enumerated() {
                guard let branch = checkout.branch, let target = mapping[branch] else {
                    notes.append("Skipped \(checkout.path): it is not on a branch.")
                    continue
                }
                state = .working("Recreating your checkouts (\(index + 1) of \(checkouts.count))")
                let name = "\(host.memberUser)-\(Self.folderName(for: checkout, branch: branch))"
                let destination = binding.remoteRoot + "/.worktrees/" + name
                // Running the import again updates checkouts created the first time.
                _ = try await cloud.runner.output(
                    CloudCommand(
                        alias: host.alias,
                        remote: .script(
                            "test -e \(ShellQuoting.quote(destination)) || "
                                + ShellQuoting.command([
                                    "git", "-C", binding.remoteRoot, "worktree", "add", destination,
                                    target,
                                ])
                        ),
                        timeout: 600
                    )
                )
                try await engine.rsync(
                    source: checkout.path,
                    destination: destination,
                    isDirectory: true,
                    excludes: TransferDefaults.cacheExcludes + ["/.git", "/.worktrees"],
                    mirrorsDeletions: true,
                    comparesContents: true,
                    progress: { _ in }
                )
                createdWorktrees.append(destination)
            }

            state = .working("Bringing your Claude history and memories")
            try await importClaudeHistory(
                checkouts: checkouts,
                serverHome: status.home,
                engine: engine
            )
            try await importRepositoryMemory(
                from: repositoryRoot, serverHome: status.home, engine: engine)

            if includesSettings {
                state = .working("Copying your Claude and git settings")
                _ = await engine.run(.initial)
                notes += engine.notes
            }
            state = .finished
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Steps

    private func pushBranches(from repositoryRoot: String) async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_SSH_COMMAND"] =
            "/usr/bin/ssh -F \(cloud.paths.configURL.path) -o BatchMode=yes -o ControlPath=none"
        let result = try await ProcessRunner.run(
            git.gitExecutable,
            [
                "-C", repositoryRoot, "push", "--force",
                "\(host.alias):\(binding.remoteRoot)",
                "refs/heads/*:refs/termuctive/import/\(host.memberUser)/*",
            ],
            environment: environment,
            timeout: 3_600
        )
        guard result.succeeded else {
            throw CloudCommandError.failed(
                command: "git push",
                status: result.status,
                message: "Your branches could not be sent. \(result.errorText)"
            )
        }
    }

    private func importClaudeHistory(
        checkouts: [GitWorktree],
        serverHome: String,
        engine: TransferEngine
    ) async throws {
        let sharedKey = ClaudeLocalData.projectKey(for: binding.remoteRoot)
        for directory in claude.projectDataDirectories(for: checkouts.map(\.path)) {
            try await engine.rsync(
                source: directory.path,
                destination: "\(serverHome)/.claude/projects/\(sharedKey)",
                isDirectory: true,
                excludes: ["/memory"],
                mirrorsDeletions: false,
                progress: { _ in }
            )
            let memories = directory.appendingPathComponent("memory")
            guard FileManager.default.fileExists(atPath: memories.path) else {
                continue
            }
            try await mergeMemories(
                from: memories.path, serverHome: serverHome, into: nil, engine: engine)
        }
    }

    /// Merges a repository's local-only memory folder, such as BlueKite's memory/.
    private func importRepositoryMemory(
        from repositoryRoot: String,
        serverHome: String,
        engine: TransferEngine
    ) async throws {
        let local = repositoryRoot + "/memory"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return
        }
        try await mergeMemories(
            from: local,
            serverHome: serverHome,
            into: binding.remoteRoot + "/memory",
            engine: engine
        )
    }

    private func mergeMemories(
        from local: String,
        serverHome: String,
        into: String?,
        engine: TransferEngine
    ) async throws {
        let staging = "\(serverHome)/.cache/termuctive/memory-import/\(UUID().uuidString.prefix(8))"
        _ = try await cloud.runner.output(
            CloudCommand(
                alias: host.alias,
                remote: .arguments([TMCClient.executable, "mkdirs"]),
                input: Data(staging.utf8)
            )
        )
        try await engine.rsync(
            source: local,
            destination: staging,
            isDirectory: true,
            excludes: [],
            mirrorsDeletions: false,
            progress: { _ in }
        )
        var arguments = [
            TMCClient.executable, "memory", "merge", "--slug", binding.slug, "--from", staging,
        ]
        if let into {
            arguments += ["--into", into]
        }
        let report = try await cloud.runner.decode(MemoryMergeReport.self, command(arguments))
        if !report.conflicts.isEmpty {
            notes.append(
                "\(report.conflicts.count) memories had a different version on the server; both "
                    + "were kept and listed in MERGE-REVIEW.md."
            )
        }
        notes += report.warnings
    }

    private func settingsEngine() -> TransferEngine {
        let home = claude.homeDirectory.path
        var items: [TransferItem] = []
        if FileManager.default.fileExists(atPath: claude.claudeDirectory.path) {
            items.append(
                TransferItem(
                    id: "claude-configuration",
                    kind: .claudeConfiguration,
                    title: "Claude settings",
                    detail: nil,
                    localPath: claude.claudeDirectory.path,
                    remotePath: claude.claudeDirectory.path,
                    isDirectory: true,
                    bytes: 0,
                    selected: true,
                    excludes: [],
                    lastActivity: nil
                )
            )
        }
        if FileManager.default.fileExists(atPath: home + "/.gitconfig") {
            items.append(
                TransferItem(
                    id: "gitconfig",
                    kind: .personalFile,
                    title: "Git settings",
                    detail: nil,
                    localPath: home + "/.gitconfig",
                    remotePath: home + "/.gitconfig",
                    isDirectory: false,
                    bytes: 0,
                    selected: true,
                    excludes: [],
                    lastActivity: nil
                )
            )
        }
        let engine = TransferEngine(
            manifest: TransferManifest(
                projectID: binding.projectID,
                projectName: "",
                projectRoot: binding.remoteRoot,
                items: items
            ),
            host: host,
            slug: binding.slug,
            runner: cloud.runner,
            paths: cloud.paths,
            claude: claude
        )
        engine.preparesProject = false
        return engine
    }

    private func command(_ arguments: [String]) -> CloudCommand {
        CloudCommand(alias: host.alias, remote: .arguments(arguments), timeout: 600)
    }

    static func folderName(for checkout: GitWorktree, branch: String) -> String {
        let base = checkout.isMain ? branch : URL(fileURLWithPath: checkout.path).lastPathComponent
        return CloudSlug.make(from: base)
    }
}

struct MemoryMergeReport: Decodable {
    let added: [String]
    let identical: [String]
    let conflicts: [String]
    let warnings: [String]
}
