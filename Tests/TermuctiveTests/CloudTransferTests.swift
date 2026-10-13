import Foundation
import XCTest

@testable import Termuctive

final class RsyncCommandTests: XCTestCase {
    func testDirectoryCopiesMirrorTheTreeIntoTheSamePath() {
        let command = RsyncCommand(configPath: "/Users/m/.termuctive/ssh/config", alias: "tmc-abc")

        let arguments = command.arguments(
            source: "/Users/m/My Project",
            destination: "/Users/m/My Project",
            isDirectory: true,
            excludes: ["node_modules", "/archive"],
            mirrorsDeletions: true
        )

        XCTAssertEqual(
            arguments,
            [
                "-rlptz", "--partial", "--progress", "--delete",
                "--exclude=node_modules", "--exclude=/archive",
                "-e",
                "/usr/bin/ssh -F /Users/m/.termuctive/ssh/config -o BatchMode=yes "
                    + "-o ControlPath=none",
                "/Users/m/My Project/", "tmc-abc:/Users/m/My\\ Project/",
            ]
        )
    }

    func testSingleFilesKeepTheirName() {
        let command = RsyncCommand(configPath: "/c", alias: "tmc-abc")

        let arguments = command.arguments(
            source: "/Users/m/.npmrc",
            destination: "/Users/m/.npmrc",
            isDirectory: false,
            excludes: [],
            mirrorsDeletions: false
        )

        XCTAssertEqual(Array(arguments.suffix(2)), ["/Users/m/.npmrc", "tmc-abc:/Users/m/.npmrc"])
        XCTAssertFalse(arguments.contains("--delete"))
    }

    func testRemotePathsEscapeEverythingTheRemoteShellWouldInterpret() {
        XCTAssertEqual(
            RsyncCommand.remotePath("/Users/m/it's a $HOME (copy)/"),
            "/Users/m/it\\'s\\ a\\ \\$HOME\\ \\(copy\\)/"
        )
        XCTAssertEqual(
            RsyncCommand.remotePath("/Users/m/plain-name_1.2/"), "/Users/m/plain-name_1.2/")
    }

    func testProgressParserReportsFilesAndCompletedBytes() {
        var parser = RsyncProgressParser()

        _ = parser.consume("building file list ... done\nsrc/app.py\n        1,024  50%  1.00MB/s")
        var progress = parser.consume(
            "\r        2,048 100%    1.95MB/s    0:00:00 (xfer#1, to-check=3/10)\nsrc/big.bin\n"
        )
        XCTAssertEqual(progress.completedFileBytes, 2_048)
        XCTAssertEqual(progress.filesRemaining, 3)
        XCTAssertEqual(progress.filesTotal, 10)
        XCTAssertEqual(progress.fraction ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertEqual(progress.currentFile, "src/big.bin")

        progress = parser.consume(
            "            6 100%  142.88KB/s   00:00:00 (xfer#2, to-check=2/10)\n")
        XCTAssertEqual(progress.completedFileBytes, 2_054)
        progress = parser.consume("sent 1234 bytes  received 56 bytes\n")
        XCTAssertEqual(progress.currentFile, "src/big.bin")
    }
}

final class GitInspectorTests: XCTestCase {
    func testWorktreePorcelainParsing() {
        let porcelain = """
            worktree /Users/m/project
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /Users/m/project/.worktrees/feature
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/feature/login

            worktree /Users/m/project/.worktrees/detached
            HEAD 3333333333333333333333333333333333333333
            detached
            locked parked

            """

        let entries = GitInspector.parseWorktrees(porcelain)

        XCTAssertEqual(entries.map(\.path).count, 3)
        XCTAssertTrue(entries[0].isMain)
        XCTAssertEqual(entries[1].branch, "feature/login")
        XCTAssertFalse(entries[1].isMain)
        XCTAssertNil(entries[2].branch)
        XCTAssertTrue(entries[2].isLocked)
    }
}

final class ClaudeLocalDataTests: XCTestCase {
    func testProjectKeysReplaceEverythingButLettersAndDigits() {
        XCTAssertEqual(
            ClaudeLocalData.projectKey(for: "/Users/m/Documents/bluekite"),
            "-Users-m-Documents-bluekite"
        )
        XCTAssertEqual(
            ClaudeLocalData.projectKey(for: "/Users/m/Documents/bluekite/.worktrees/team_chat"),
            "-Users-m-Documents-bluekite--worktrees-team-chat"
        )
    }

    func testHistoryFoldersAreConfirmedByTheirRecordedDirectory() throws {
        let home = try makeTemporaryDirectory()
        let claude = ClaudeLocalData(homeDirectory: home)
        let root = "/Users/m/Documents/bluekite"
        try makeHistory(claude, root: root, cwd: root)
        try makeHistory(claude, root: root + "/memory", cwd: root + "/memory")
        try makeHistory(claude, root: root + "-old", cwd: root + "-old")
        try makeHistory(claude, root: "/Users/m/other", cwd: "/Users/m/other")

        let found = claude.projectDataDirectories(for: [root]).map(\.lastPathComponent)

        XCTAssertEqual(
            found,
            ["-Users-m-Documents-bluekite", "-Users-m-Documents-bluekite-memory"]
        )
    }

    func testGlobalConfigSubsetKeepsOnlyThisProjectAndUserMCPServers() throws {
        let home = try makeTemporaryDirectory()
        let config: [String: Any] = [
            "projects": [
                "/Users/m/p": ["hasTrustDialogAccepted": true],
                "/Users/m/p/.worktrees/a": ["allowedTools": ["Bash"]],
                "/Users/m/other": [:],
            ],
            "mcpServers": ["docs": ["command": "npx"]],
            "oauthAccount": ["emailAddress": "private@example.com"],
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: home.appendingPathComponent(".claude.json"))

        let data = try XCTUnwrap(
            ClaudeLocalData(homeDirectory: home).globalConfigSubset(for: ["/Users/m/p"])
        )
        let subset = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set((subset["projects"] as? [String: Any])?.keys ?? [:].keys),
            ["/Users/m/p", "/Users/m/p/.worktrees/a"]
        )
        XCTAssertNotNil(subset["mcpServers"])
        XCTAssertNil(subset["oauthAccount"])
    }

    private func makeHistory(_ claude: ClaudeLocalData, root: String, cwd: String) throws {
        let directory = claude.projectsDirectory
            .appendingPathComponent(ClaudeLocalData.projectKey(for: root))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": cwd])
        try (line + Data("\n".utf8)).write(to: directory.appendingPathComponent("a.jsonl"))
    }
}

final class PathReferenceScannerTests: XCTestCase {
    func testFindsHomeFoldersMentionedInRulesAndMemories() {
        let scanner = PathReferenceScanner(homeDirectory: "/Users/m")
        let text = """
            Reports live in ~/model-data/live/<date>/fast and data in $HOME/datasets.
            Old checkout: /Users/m/Documents/telesales; recordings in ~/Downloads/Calls 2026.
            Ignore ~/Library/Caches, ~/.claude/projects and ~/.local/bin/docker.
            """

        XCTAssertEqual(
            scanner.referencedFolders(inText: text),
            [
                "/Users/m/model-data",
                "/Users/m/datasets",
                "/Users/m/Documents/telesales",
                "/Users/m/Downloads/Calls 2026",
            ]
        )
    }
}

@MainActor
final class ProjectScannerTests: XCTestCase {
    func testScanningAFixtureProjectFindsEverythingThatMoves() async throws {
        let home = try makeTemporaryDirectory()
        let root = home.appendingPathComponent("Documents/project").path
        try git(["init", "-q", root])
        try git(["-C", root, "config", "user.email", "t@example.com"])
        try git(["-C", root, "config", "user.name", "T"])
        try "node_modules/\narchive/\n.env\n.worktrees/\n".write(
            toFile: root + "/.gitignore",
            atomically: true,
            encoding: .utf8
        )
        try "Read ~/ext-data before training.\n".write(
            toFile: root + "/CLAUDE.md",
            atomically: true,
            encoding: .utf8
        )
        try git(["-C", root, "add", "."])
        try git(["-C", root, "commit", "-q", "-m", "start"])
        try git([
            "-C", root, "worktree", "add", "-q", "-b", "feature", root + "/.worktrees/feature",
        ])
        for directory in ["archive", "node_modules/pkg", ".worktrees/feature/node_modules"] {
            try FileManager.default.createDirectory(
                atPath: root + "/" + directory,
                withIntermediateDirectories: true
            )
        }
        try "SECRET=1\n".write(toFile: root + "/.env", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("ext-data"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".aws"),
            withIntermediateDirectories: true
        )
        let claude = ClaudeLocalData(homeDirectory: home)
        let history = claude.projectsDirectory
            .appendingPathComponent(ClaudeLocalData.projectKey(for: root))
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)

        var scanner = ProjectScanner(claude: claude, homeDirectory: home.path)
        scanner.sizer = { path, _ in
            path.hasSuffix("/archive") ? 2 * 1024 * 1024 * 1024 : 1_000
        }
        let manifest = try await scanner.scan(
            projectID: UUID(),
            projectName: "project",
            root: root,
            paneDirectories: [root + "/.worktrees/feature"]
        )

        let byKind = Dictionary(grouping: manifest.items, by: \.kind)
        let project = try XCTUnwrap(byKind[.project]?.first)
        XCTAssertEqual(manifest.projectRoot, root)
        XCTAssertTrue(project.excludes.contains("node_modules"))
        XCTAssertTrue(project.excludes.contains("/archive"))
        XCTAssertTrue(project.excludes.contains("/.worktrees/feature"))
        XCTAssertEqual(byKind[.worktree]?.map(\.localPath), [root + "/.worktrees/feature"])
        XCTAssertTrue(byKind[.worktree]?.first?.detail?.hasPrefix("feature") ?? false)
        XCTAssertEqual(byKind[.largeFolder]?.map(\.localPath), [root + "/archive"])
        XCTAssertEqual(byKind[.claudeHistory]?.map(\.localPath), [history.path])
        XCTAssertEqual(byKind[.relatedFolder]?.map(\.localPath), [home.path + "/ext-data"])
        XCTAssertEqual(byKind[.personalFolder]?.map(\.localPath), [home.path + "/.aws"])
        XCTAssertTrue(manifest.items.allSatisfy { $0.localPath == $0.remotePath })
    }

    func testSetupCommandHydratesOpenAndRecentCheckoutsThenShowsTheChecklist() {
        let now = Date()
        var items = [
            item(kind: .project, path: "/Users/m/p", activity: nil),
            item(kind: .worktree, path: "/Users/m/p/.worktrees/new one", activity: now - 60),
            item(kind: .worktree, path: "/Users/m/p/.worktrees/old", activity: now - 9_000_000),
        ]
        for index in 0..<5 {
            items.append(
                item(
                    kind: .worktree,
                    path: "/Users/m/p/.worktrees/recent\(index)",
                    activity: now - Double(120 + index)
                )
            )
        }
        let manifest = TransferManifest(
            projectID: UUID(),
            projectName: "p",
            projectRoot: "/Users/m/p",
            items: items
        )

        let command = ProjectMove.setupCommand(
            for: manifest,
            paneDirectories: ["/Users/m/p/.worktrees/old/src"],
            now: now
        )

        XCTAssertEqual(
            command,
            "/opt/termuctive/bin/tmc hydrate --root /Users/m/p; "
                + "/opt/termuctive/bin/tmc hydrate --root /Users/m/p/.worktrees/old; "
                + "/opt/termuctive/bin/tmc hydrate --root '/Users/m/p/.worktrees/new one'; "
                + "/opt/termuctive/bin/tmc hydrate --root /Users/m/p/.worktrees/recent0; "
                + "/opt/termuctive/bin/tmc hydrate --root /Users/m/p/.worktrees/recent1; "
                + "/opt/termuctive/bin/tmc checklist --root /Users/m/p"
        )
    }

    private func item(kind: TransferItem.Kind, path: String, activity: Date?) -> TransferItem {
        TransferItem(
            id: path,
            kind: kind,
            title: path,
            detail: nil,
            localPath: path,
            remotePath: path,
            isDirectory: true,
            bytes: 1,
            selected: true,
            excludes: [],
            lastActivity: activity
        )
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}

@MainActor
final class ProjectDuplicationTests: XCTestCase {
    func testDuplicatingAProjectCopiesLayoutWithNewIdentifiers() throws {
        let store = WorkspaceStore(persistence: TransferTestWorkspacePersistence())
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let project = try XCTUnwrap(store.selectedProject)
        store.addNote(toFolderWithID: nil, inProjectWithID: project.id)
        let noteID = try XCTUnwrap(store.document.projects[0].items.flatMap(\.notes).first?.id)
        let firstSpace = try XCTUnwrap(store.document.projects[0].items.first?.firstSpace)
        store.selectSpace(withID: firstSpace.id, inProject: project.id)
        store.focusPane(withID: firstSpace.layout.firstTerminalID)
        store.splitFocusedPane(axis: .horizontal)

        let duplicate = try XCTUnwrap(
            store.duplicateProject(withID: project.id, name: "\(project.name) (Cloud)")
        )

        let copy = try XCTUnwrap(store.document.projects.first { $0.id == duplicate.projectID })
        XCTAssertEqual(store.document.projects.count, 2)
        XCTAssertEqual(store.document.projects[1].id, copy.id)
        XCTAssertEqual(copy.name, "tmp (Cloud)")
        XCTAssertEqual(copy.rootDirectory, project.rootDirectory)
        XCTAssertEqual(duplicate.paneIDs.count, 2)
        XCTAssertTrue(
            Set(duplicate.paneIDs.values).isDisjoint(with: store.document.projects[0].terminalIDs)
        )
        XCTAssertEqual(copy.terminalIDs, Set(duplicate.paneIDs.values))
        XCTAssertEqual(copy.items.flatMap(\.notes).map(\.id), [duplicate.noteIDs[noteID]])
        XCTAssertEqual(store.selectedProject?.id, copy.id)
    }

    func testDuplicatingNotesStoresCopiesUnderTheirNewIdentifiers() throws {
        let persistence = TransferTestNotePersistence()
        let original = UUID()
        let copy = UUID()
        try persistence.save(NoteDocument(noteID: original, richTextRTF: Data("rtf".utf8)))
        let notes = NoteSessionPool(persistence: persistence)

        try notes.duplicateNotes([original: copy])

        XCTAssertEqual(try persistence.load(noteID: copy)?.richTextRTF, Data("rtf".utf8))
        XCTAssertNotNil(try persistence.load(noteID: original))
    }
}

@MainActor
final class CloudPortForwarderTests: XCTestCase {
    func testForwardsNewPortsAndCancelsOnesThatStop() async throws {
        let host = CloudHost(name: "S", address: "s", adminUser: "a", memberUser: "m")
        let store = CloudStore(
            persistence: InMemoryCloudPersistence(
                initialState: CloudState(
                    hosts: [host],
                    bindings: [
                        CloudProjectBinding(
                            projectID: UUID(),
                            hostID: host.id,
                            slug: "p",
                            remoteRoot: "/x",
                            role: .owner
                        )
                    ]
                )
            )
        )
        let listening = ListeningPorts(
            #"[{"port": 5173, "pid": 10, "command": "node"},"#
                + #"{"port": 8000, "pid": 11, "command": "python3"}]"#)
        let runner = RecordingCloudRunner { _ in
            ProcessResult(
                status: 0,
                output: Data(listening.value.utf8),
                error: Data(),
                timedOut: false
            )
        }
        let control = RecordingControl()
        let forwarder = CloudPortForwarder(
            cloudStore: store,
            runner: runner,
            control: control,
            isLocalPortFree: { $0 != 8000 }
        )

        await forwarder.refresh()

        XCTAssertEqual(forwarder.forwards.map(\.port), [5173])
        XCTAssertEqual(forwarder.blockedPorts, [8000])
        XCTAssertEqual(control.events, ["forward 5173"])

        listening.value = "[]"
        await forwarder.refresh()

        XCTAssertTrue(forwarder.forwards.isEmpty)
        XCTAssertEqual(control.events, ["forward 5173", "cancel 5173"])
    }
}

private final class ListeningPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(_ value: String) {
        stored = value
    }

    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class RecordingControl: CloudControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.withLock { recorded }
    }

    func ensureMaster(alias: String) async {}
    func reset(alias: String) async {}
    func resetAll(aliases: [String]) async {}

    func forward(port: Int, alias: String) async -> Bool {
        lock.withLock { recorded.append("forward \(port)") }
        return true
    }

    func cancelForward(port: Int, alias: String) async {
        lock.withLock { recorded.append("cancel \(port)") }
    }
}

private final class TransferTestWorkspacePersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}

private final class TransferTestNotePersistence: NotePersisting {
    private var documents: [UUID: NoteDocument] = [:]

    func load(noteID: UUID) throws -> NoteDocument? {
        documents[noteID]
    }

    func save(_ document: NoteDocument) throws {
        documents[document.noteID] = document
    }

    func archive(noteID: UUID) throws {
        documents.removeValue(forKey: noteID)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("termuctive-transfer-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
