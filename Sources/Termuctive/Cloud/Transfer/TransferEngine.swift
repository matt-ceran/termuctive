import Foundation
import IOKit.pwr_mgt

/// Copies a project's manifest to a cloud server with rsync.
///
/// Every step is safe to repeat: running a pass again only sends what changed, which is
/// how an interrupted move resumes and how the final pass catches up before switching.
@MainActor
final class TransferEngine: ObservableObject {
    enum Pass: Equatable {
        /// Copies everything while the project stays in use on this Mac.
        case initial
        /// Catches up after local work stops, removing files deleted since the first pass.
        case final
    }

    enum State: Equatable {
        case idle
        case running
        case finished
        case failed(String)
        case cancelled
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTitle = ""
    @Published private(set) var currentFile: String?
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var notes: [String] = []

    let manifest: TransferManifest
    let host: CloudHost
    let slug: String

    private let runner: any CloudCommandRunning
    private let paths: SSHPaths
    private let claude: ClaudeLocalData
    private var runningTask: Task<Bool, Never>?

    init(
        manifest: TransferManifest,
        host: CloudHost,
        slug: String,
        runner: any CloudCommandRunning,
        paths: SSHPaths,
        claude: ClaudeLocalData = ClaudeLocalData()
    ) {
        self.manifest = manifest
        self.host = host
        self.slug = slug
        self.runner = runner
        self.paths = paths
        self.claude = claude
    }

    var fractionComplete: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }

    var isRunning: Bool {
        state == .running
    }

    func run(_ pass: Pass) async -> Bool {
        let task = Task { await perform(pass) }
        runningTask = task
        return await task.value
    }

    func cancel() {
        runningTask?.cancel()
    }

    private func perform(_ pass: Pass) async -> Bool {
        state = .running
        notes = []
        completedBytes = 0
        totalBytes = max(1, manifest.selectedBytes)
        let assertion = SleepAssertion(reason: "Termuctive is moving a project to the cloud")
        defer {
            assertion.release()
        }

        do {
            if pass == .initial {
                currentTitle = "Preparing the server"
                _ = try await TMCClient(runner: runner).createProject(
                    alias: host.alias,
                    slug: slug,
                    root: manifest.projectRoot,
                    owner: host.memberUser
                )
            }
            try await makeRemoteDirectories()

            var finishedBytes: Int64 = 0
            for item in manifest.selectedItems {
                try Task.checkCancellation()
                currentTitle = item.title
                currentFile = nil
                try await copy(item, pass: pass) { [weak self] bytes in
                    self?.completedBytes = finishedBytes + min(bytes, item.bytes)
                }
                finishedBytes += item.bytes
                completedBytes = finishedBytes
            }

            currentTitle = "Finishing on the server"
            currentFile = nil
            let report = try await runner.decode(
                FinalizeReport.self,
                CloudCommand(
                    alias: host.alias,
                    remote: .arguments([
                        TMCClient.executable, "finalize", "--root", manifest.projectRoot,
                    ]),
                    timeout: 300
                )
            )
            notes += report.git
            completedBytes = totalBytes
            state = .finished
            return true
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = .failed(error.localizedDescription)
        }
        return false
    }

    // MARK: Steps

    private func makeRemoteDirectories() async throws {
        var directories = Set<String>()
        for item in manifest.selectedItems {
            directories.insert(
                item.isDirectory
                    ? item.remotePath
                    : URL(fileURLWithPath: item.remotePath).deletingLastPathComponent().path
            )
        }
        _ = try await runner.output(
            CloudCommand(
                alias: host.alias,
                remote: .arguments([TMCClient.executable, "mkdirs"]),
                input: Data(directories.sorted().joined(separator: "\n").utf8)
            )
        )
    }

    private func copy(
        _ item: TransferItem,
        pass: Pass,
        progress: @escaping @MainActor (Int64) -> Void
    ) async throws {
        switch item.kind {
        case .claudeConfiguration:
            try await copyClaudeConfiguration(item, progress: progress)
        case .personalFile
        where URL(fileURLWithPath: item.localPath).lastPathComponent
            == ".gitconfig":
            try await importGitConfiguration(item)
        default:
            try await rsync(
                source: item.localPath,
                destination: item.remotePath,
                isDirectory: item.isDirectory,
                excludes: item.excludes,
                mirrorsDeletions: pass == .final && item.mirrorsDeletions,
                progress: progress
            )
        }
    }

    private func rsync(
        source: String,
        destination: String,
        isDirectory: Bool,
        excludes: [String],
        mirrorsDeletions: Bool,
        filesFrom: String? = nil,
        progress: @escaping @MainActor (Int64) -> Void
    ) async throws {
        let command = RsyncCommand(configPath: paths.configURL.path, alias: host.alias)
        let parser = ProgressBox()
        let result = try await ProcessRunner.stream(
            RsyncCommand.executable,
            command.arguments(
                source: source,
                destination: destination,
                isDirectory: isDirectory,
                excludes: excludes,
                mirrorsDeletions: mirrorsDeletions,
                filesFrom: filesFrom
            )
        ) { [weak self] text in
            let snapshot = parser.consume(text)
            Task { @MainActor in
                self?.currentFile = snapshot.currentFile
                progress(snapshot.completedFileBytes)
            }
        }
        try Task.checkCancellation()
        switch result.status {
        case 0:
            return
        case 24:
            // Files vanished while copying, which happens when work continues meanwhile.
            notes.append(
                "Some files in \(source) changed while copying; the final pass catches up.")
        case 23:
            notes.append(
                "Some files in \(source) could not be copied: "
                    + result.errorText.split(separator: "\n").prefix(3).joined(separator: "; ")
            )
        default:
            throw CloudCommandError.failed(
                command: "rsync",
                status: result.status,
                message: "Copying \(source) failed. \(result.errorText)"
            )
        }
    }

    private func copyClaudeConfiguration(
        _ item: TransferItem,
        progress: @escaping @MainActor (Int64) -> Void
    ) async throws {
        let entries = ClaudeLocalData.portableEntries.filter { name in
            FileManager.default.fileExists(
                atPath: claude.claudeDirectory.appendingPathComponent(name).path
            )
        }
        if !entries.isEmpty {
            let list = FileManager.default.temporaryDirectory
                .appendingPathComponent("termuctive-claude-\(UUID().uuidString).txt")
            try entries.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            defer {
                try? FileManager.default.removeItem(at: list)
            }
            try await rsync(
                source: claude.claudeDirectory.path,
                destination: item.remotePath,
                isDirectory: true,
                excludes: [],
                mirrorsDeletions: false,
                filesFrom: list.path,
                progress: progress
            )
        }

        let settingsURL = claude.claudeDirectory.appendingPathComponent("settings.json")
        if let settings = try? Data(contentsOf: settingsURL) {
            let report = try await runner.decode(
                ClaudeImportReport.self,
                CloudCommand(
                    alias: host.alias,
                    remote: .arguments([TMCClient.executable, "claude", "import-settings"]),
                    input: settings
                )
            )
            notes += (report.disabled ?? []).map { "Turned off on the server (macOS only): \($0)" }
        }
        if let subset = claude.globalConfigSubset(for: manifest.checkoutRoots) {
            let report = try await runner.decode(
                ClaudeImportReport.self,
                CloudCommand(
                    alias: host.alias,
                    remote: .arguments([TMCClient.executable, "claude", "import-config"]),
                    input: subset
                )
            )
            for name in report.skipped ?? [] {
                notes.append("MCP server \(name) was not copied; its command is not on the server.")
            }
        }
    }

    private func importGitConfiguration(_ item: TransferItem) async throws {
        guard let contents = try? Data(contentsOf: URL(fileURLWithPath: item.localPath)) else {
            return
        }
        let report = try await runner.decode(
            GitConfigReport.self,
            CloudCommand(
                alias: host.alias,
                remote: .arguments([TMCClient.executable, "gitconfig", "import"]),
                input: contents
            )
        )
        if !report.removed.isEmpty {
            notes.append(
                "Mac-only git settings left out: \(report.removed.joined(separator: ", "))")
        }
    }
}

struct FinalizeReport: Decodable {
    let root: String
    let git: [String]
    let environmentFiles: [String]
}

struct ClaudeImportReport: Decodable {
    let disabled: [String]?
    let skipped: [String]?
}

struct GitConfigReport: Decodable {
    let path: String
    let removed: [String]
}

/// Parser state shared with the output callback, which runs off the main thread.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = RsyncProgressParser()

    func consume(_ text: String) -> RsyncProgress {
        lock.lock()
        defer { lock.unlock() }
        return parser.consume(text)
    }
}

/// Keeps the Mac awake while a long copy runs.
final class SleepAssertion {
    private var identifier: IOPMAssertionID = 0

    init(reason: String) {
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &identifier
        )
    }

    func release() {
        guard identifier != 0 else {
            return
        }
        IOPMAssertionRelease(identifier)
        identifier = 0
    }
}
