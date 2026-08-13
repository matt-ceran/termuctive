import AppKit
import Combine
import SwiftUI
import XCTest

@testable import Termuctive

@MainActor
final class TerminalAgentActivityTests: XCTestCase {
    func testMatcherRecognizesSupportedNativeClientsAndRejectsSubstrings() {
        let expectedKinds: [(String, TerminalAgentKind)] = [
            ("aider", .aider),
            ("claude", .claude),
            ("codex", .codex),
            ("copilot", .copilot),
            ("gemini", .gemini),
            ("goose", .goose),
            ("opencode", .openCode),
        ]

        for (name, expectedKind) in expectedKinds {
            XCTAssertEqual(
                TerminalAgentProcessMatcher.kind(
                    for: processRecord(path: "/usr/local/bin/\(name)")
                ),
                expectedKind
            )
        }

        XCTAssertNil(
            TerminalAgentProcessMatcher.kind(
                for: processRecord(
                    path: "/usr/bin/rg",
                    arguments: ["rg", "codex is working"]
                )
            )
        )
        XCTAssertNil(
            TerminalAgentProcessMatcher.kind(
                for: processRecord(path: "/tmp/codex-helper")
            )
        )
    }

    func testMatcherRecognizesKnownWrappersWithoutSearchingPromptArguments() {
        XCTAssertEqual(
            TerminalAgentProcessMatcher.kind(
                for: processRecord(
                    path: "/usr/local/bin/node",
                    arguments: [
                        "node",
                        "/opt/node_modules/@openai/codex/bin/codex.js",
                        "prompt containing claude and gemini",
                    ]
                )
            ),
            .codex
        )
        XCTAssertEqual(
            TerminalAgentProcessMatcher.kind(
                for: processRecord(
                    path: "/usr/bin/python3",
                    arguments: ["python3", "-m", "aider"]
                )
            ),
            .aider
        )
        XCTAssertEqual(
            TerminalAgentProcessMatcher.kind(
                for: processRecord(
                    path: "/opt/homebrew/bin/gh",
                    arguments: ["gh", "copilot", "suggest"]
                )
            ),
            .copilot
        )
        XCTAssertNil(
            TerminalAgentProcessMatcher.kind(
                for: processRecord(
                    path: "/usr/local/bin/node",
                    arguments: ["node", "/tmp/tool.js", "ask codex to review this"]
                )
            )
        )
    }

    func testCArgumentReaderClassifiesARealWrapperProcess() async throws {
        let wrapper = try fixtureExecutable(named: "node")
        let process = Process()
        let standardInput = Pipe()
        process.executableURL = wrapper
        process.arguments = [
            "/opt/node_modules/@openai/codex/bin/codex.js",
            "prompt containing claude",
        ]
        process.standardInput = standardInput
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            try? standardInput.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        var arguments: [String] = []
        try await waitUntil("the wrapper arguments to become readable", timeout: 3) {
            arguments = MacAgentProcessInspector.processArguments(
                for: Int32(process.processIdentifier)
            )
            return arguments.count >= 2
        }

        XCTAssertEqual(
            TerminalAgentProcessMatcher.kind(
                for: processRecord(path: wrapper.path, arguments: arguments)
            ),
            .codex
        )
    }

    func testRegistryAggregatesNestedScopesAndIgnoresNotePanes() throws {
        let firstPane = TerminalPane(workingDirectory: "/tmp")
        let secondPane = TerminalPane(workingDirectory: "/tmp")
        let notePane = TerminalPane(
            workingDirectory: "/tmp",
            content: .note(UUID())
        )
        let firstSpace = TerminalSpace(
            name: "First",
            layout: .terminal(firstPane)
        )
        let secondSpace = TerminalSpace(
            name: "Second",
            layout: .split(
                PaneSplit(
                    axis: .horizontal,
                    first: .terminal(secondPane),
                    second: .terminal(notePane)
                )
            )
        )
        let innerFolder = WorkspaceFolder(
            name: "Inner",
            children: [.space(firstSpace), .space(secondSpace)]
        )
        let outerFolder = WorkspaceFolder(
            name: "Outer",
            children: [.folder(innerFolder)]
        )
        let project = TerminalProject(
            name: "Activity",
            rootDirectory: "/tmp",
            items: [.folder(outerFolder)]
        )
        let registry = AgentActivityRegistry()
        registry.reconcile(
            topology: WorkspaceActivityTopology(
                document: WorkspaceDocument(projects: [project])
            )
        )

        let firstSession = UUID()
        let secondSession = UUID()
        let noteSession = UUID()
        let projectSignal = registry.signal(for: .project(project.id))
        let outerSignal = registry.signal(for: .folder(outerFolder.id))
        let innerSignal = registry.signal(for: .folder(innerFolder.id))
        let firstSpaceSignal = registry.signal(for: .space(firstSpace.id))
        let secondSpaceSignal = registry.signal(for: .space(secondSpace.id))

        registry.beginSession(paneID: firstPane.id, sessionID: firstSession)
        registry.setActivity(
            .active([.codex]),
            paneID: firstPane.id,
            sessionID: firstSession
        )

        XCTAssertEqual(firstSpaceSignal.summary.phase, .active)
        XCTAssertEqual(innerSignal.summary.phase, .active)
        XCTAssertEqual(outerSignal.summary.phase, .active)
        XCTAssertEqual(projectSignal.summary.phase, .active)
        XCTAssertEqual(secondSpaceSignal.summary, .absent)

        registry.beginSession(paneID: secondPane.id, sessionID: secondSession)
        registry.setActivity(
            .active([.claude]),
            paneID: secondPane.id,
            sessionID: secondSession
        )

        XCTAssertEqual(projectSignal.summary.kinds, [.claude, .codex])
        XCTAssertEqual(projectSignal.summary.sessionCount, 2)
        XCTAssertEqual(secondSpaceSignal.summary.phase, .active)

        registry.endSession(paneID: secondPane.id, sessionID: secondSession)
        XCTAssertEqual(projectSignal.summary.kinds, [.codex])
        XCTAssertEqual(projectSignal.summary.sessionCount, 1)

        registry.beginSession(paneID: notePane.id, sessionID: noteSession)
        registry.setActivity(
            .active([.gemini]),
            paneID: notePane.id,
            sessionID: noteSession
        )
        XCTAssertEqual(secondSpaceSignal.summary, .absent)
        XCTAssertEqual(projectSignal.summary.kinds, [.codex])
    }

    func testRegistryRejectsStaleSessionUpdatesAndPrunesRemovedPanes() {
        let pane = TerminalPane(workingDirectory: "/tmp")
        let space = TerminalSpace(name: "Terminal", layout: .terminal(pane))
        let project = TerminalProject(
            name: "Activity",
            rootDirectory: "/tmp",
            items: [.space(space)]
        )
        let registry = AgentActivityRegistry()
        registry.reconcile(
            topology: WorkspaceActivityTopology(
                document: WorkspaceDocument(projects: [project])
            )
        )
        let signal = registry.signal(for: .space(space.id))
        let oldSession = UUID()
        let currentSession = UUID()

        registry.beginSession(paneID: pane.id, sessionID: oldSession)
        registry.setActivity(.active([.codex]), paneID: pane.id, sessionID: oldSession)
        registry.beginSession(paneID: pane.id, sessionID: currentSession)
        XCTAssertEqual(signal.summary, .absent)

        registry.setActivity(.active([.claude]), paneID: pane.id, sessionID: oldSession)
        registry.endSession(paneID: pane.id, sessionID: oldSession)
        XCTAssertEqual(signal.summary, .absent)

        registry.setActivity(.active([.gemini]), paneID: pane.id, sessionID: currentSession)
        XCTAssertEqual(signal.summary.kinds, [.gemini])

        registry.reconcile(topology: WorkspaceActivityTopology(document: WorkspaceDocument()))
        XCTAssertEqual(signal.summary, .absent)

        registry.setActivity(.active([.codex]), paneID: pane.id, sessionID: currentSession)
        XCTAssertEqual(signal.summary, .absent)
    }

    func testMonitorCoalescesTransitionsAndPreservesStateAcrossTransientFailure() async {
        let paneID = UUID()
        let sessionID = UUID()
        let identity = shellIdentity(processID: 123)
        let activeSnapshot = AgentProcessSnapshot(
            shellIdentity: identity,
            processes: [AgentProcessSample(processID: 456, kind: .codex)]
        )
        let inspector = LockedAgentProcessInspector(
            identity: identity,
            inspection: .snapshot(activeSnapshot)
        )
        var updates: [TerminalAgentActivity] = []
        let monitor = TerminalAgentActivityMonitor(
            inspector: inspector,
            automaticallyPolls: false
        ) { _, _, activity in
            updates.append(activity)
        }

        await monitor.register(
            paneID: paneID,
            shellPID: identity.processID,
            shellIdentity: identity,
            sessionID: sessionID
        )
        await monitor.pollNow()
        await monitor.pollNow()
        XCTAssertEqual(updates, [.active([.codex])])

        inspector.inspection = .unavailable
        await monitor.pollNow()
        XCTAssertEqual(updates, [.active([.codex])])

        inspector.inspection = .snapshot(activeSnapshot)
        await monitor.pollNow()
        XCTAssertEqual(updates, [.active([.codex])])

        inspector.inspection = .unavailable
        await monitor.pollNow()
        await monitor.pollNow()
        XCTAssertEqual(updates.map(\.phase), [.active, .absent])

        inspector.inspection = .snapshot(activeSnapshot)
        await monitor.requestImmediatePoll(paneID: paneID, sessionID: sessionID)
        XCTAssertEqual(updates.map(\.phase), [.active, .absent, .active])

        inspector.inspection = .shellTerminated
        await monitor.pollNow()
        XCTAssertEqual(updates.map(\.phase), [.active, .absent, .active, .absent])

        inspector.inspection = .snapshot(activeSnapshot)
        await monitor.requestImmediatePoll(paneID: paneID, sessionID: sessionID)
        XCTAssertEqual(updates.map(\.phase), [.active, .absent, .active, .absent])
        await monitor.stopAll()
    }

    func testMonitorRejectsStaleSessionsIdentityMismatchAndPostStopRegistration() async {
        let paneID = UUID()
        let firstSession = UUID()
        let currentSession = UUID()
        let postStopSession = UUID()
        let identity = shellIdentity(processID: 123)
        let otherIdentity = shellIdentity(processID: 999)
        let inspector = LockedAgentProcessInspector(
            identity: identity,
            inspection: .snapshot(
                AgentProcessSnapshot(
                    shellIdentity: identity,
                    processes: [AgentProcessSample(processID: 456, kind: .codex)]
                )
            )
        )
        var updates: [(UUID, TerminalAgentActivity)] = []
        let monitor = TerminalAgentActivityMonitor(
            inspector: inspector,
            automaticallyPolls: false
        ) { _, sessionID, activity in
            updates.append((sessionID, activity))
        }

        await monitor.register(
            paneID: paneID,
            shellPID: identity.processID,
            shellIdentity: identity,
            sessionID: firstSession
        )
        await monitor.register(
            paneID: paneID,
            shellPID: identity.processID,
            shellIdentity: identity,
            sessionID: currentSession
        )
        await monitor.unregister(paneID: paneID, sessionID: firstSession)
        await monitor.pollNow()
        XCTAssertEqual(updates.last?.0, currentSession)
        XCTAssertEqual(updates.last?.1, .active([.codex]))

        inspector.inspection = .snapshot(
            AgentProcessSnapshot(
                shellIdentity: otherIdentity,
                processes: [AgentProcessSample(processID: 777, kind: .claude)]
            )
        )
        await monitor.pollNow()
        XCTAssertEqual(updates.last?.1, .absent)

        await monitor.stopAll()
        inspector.inspection = .snapshot(
            AgentProcessSnapshot(
                shellIdentity: identity,
                processes: [AgentProcessSample(processID: 456, kind: .codex)]
            )
        )
        await monitor.register(
            paneID: paneID,
            shellPID: identity.processID,
            shellIdentity: identity,
            sessionID: postStopSession
        )
        await monitor.pollNow()
        XCTAssertEqual(updates.last?.1, .absent)
    }

    func testAutomaticMonitorWakesForActiveCadenceWithoutAcceleratingIdleSessions() async throws {
        let activePaneID = UUID()
        let idlePaneID = UUID()
        let activeSessionID = UUID()
        let idleSessionID = UUID()
        let activeIdentity = shellIdentity(processID: 123)
        let idleIdentity = shellIdentity(processID: 124)
        let inspector = CountingAgentProcessInspector(
            inspections: [
                activeIdentity.processID: .snapshot(
                    AgentProcessSnapshot(
                        shellIdentity: activeIdentity,
                        processes: []
                    )
                ),
                idleIdentity.processID: .snapshot(
                    AgentProcessSnapshot(
                        shellIdentity: idleIdentity,
                        processes: []
                    )
                ),
            ]
        )
        var updates: [TerminalAgentActivity] = []
        let monitor = TerminalAgentActivityMonitor(
            inspector: inspector,
            activePollIntervalNanoseconds: 80_000_000,
            idlePollIntervalNanoseconds: 1_000_000_000
        ) { paneID, _, activity in
            if paneID == activePaneID {
                updates.append(activity)
            }
        }

        await monitor.register(
            paneID: activePaneID,
            shellPID: activeIdentity.processID,
            shellIdentity: activeIdentity,
            sessionID: activeSessionID
        )
        await monitor.register(
            paneID: idlePaneID,
            shellPID: idleIdentity.processID,
            shellIdentity: idleIdentity,
            sessionID: idleSessionID
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        inspector.resetCounts()
        inspector.setInspection(
            .snapshot(
                AgentProcessSnapshot(
                    shellIdentity: activeIdentity,
                    processes: [AgentProcessSample(processID: 456, kind: .codex)]
                )
            ),
            for: activeIdentity.processID
        )

        await monitor.requestImmediatePoll(
            paneID: activePaneID,
            sessionID: activeSessionID
        )
        XCTAssertEqual(updates.last?.phase, .active)
        inspector.setInspection(
            .snapshot(
                AgentProcessSnapshot(
                    shellIdentity: activeIdentity,
                    processes: []
                )
            ),
            for: activeIdentity.processID
        )

        try await waitUntil("the active monitor cadence to clear the agent", timeout: 0.8) {
            updates.last?.phase == .absent
        }
        XCTAssertGreaterThanOrEqual(inspector.inspectionCount(for: activeIdentity.processID), 2)
        XCTAssertEqual(inspector.inspectionCount(for: idleIdentity.processID), 0)
        await monitor.stopAll()
    }

    func testRealPTYAgentLifecyclePipelineAndBackgroundIsolation() async throws {
        let fixture = try fixtureExecutable(named: "codex")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termuctive-agent-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let persistence = CountingAgentWorkspacePersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: directory)
        let space = try XCTUnwrap(store.selectedSpace)
        let pane = try XCTUnwrap(space.layout.terminal(withID: space.layout.firstTerminalID))
        let registry = AgentActivityRegistry()
        registry.reconcile(topology: WorkspaceActivityTopology(document: store.document))
        let shell = TerminalShellConfiguration(
            executable: "/bin/sh",
            execName: "sh",
            baseEnvironment: ProcessInfo.processInfo.environment
        )
        let sessions = TerminalSessionPool(
            store: store,
            shellConfiguration: shell,
            agentActivityRegistry: registry
        )
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }
        terminal.frame = NSRect(x: 0, y: 0, width: 700, height: 480)

        let readyMarker = "TERMUCTIVE_AGENT_READY_\(UUID().uuidString.prefix(8))"
        terminal.send(txt: "printf '\(readyMarker)\\n'\n")
        try await waitUntil("the isolated shell to become ready", timeout: 5) {
            self.terminalOutput(terminal).contains(readyMarker)
        }

        let signal = registry.signal(for: .space(space.id))
        var poolPublicationCount = 0
        let poolObservation = sessions.objectWillChange.sink {
            poolPublicationCount += 1
        }
        defer {
            poolObservation.cancel()
        }
        let baselineSaveCount = persistence.saveCount
        let originalTerminal = terminal
        let quotedFixture = shellQuote(fixture.path)

        terminal.send(txt: "\(quotedFixture) | /bin/cat\n")
        try await waitUntil("the Codex fixture pipeline to become active", timeout: 6) {
            signal.summary.phase == .active
                && signal.summary.kinds == [.codex]
        }

        let echoMarker = "TERMUCTIVE_AGENT_ECHO_\(UUID().uuidString.prefix(8))"
        terminal.send(txt: "\(echoMarker)\n")
        try await waitUntil("the Codex fixture to echo terminal input", timeout: 3) {
            self.terminalOutput(terminal).contains(echoMarker)
        }
        XCTAssertEqual(signal.summary.phase, .active)

        terminal.send(txt: "\u{4}")
        try await waitUntil("the Codex fixture to leave the foreground", timeout: 6) {
            signal.summary.phase == .absent
        }

        terminal.send(txt: "\(quotedFixture) &\n")
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(signal.summary, .absent)
        terminal.send(txt: "kill $!\n")

        XCTAssertTrue(originalTerminal === sessions.terminalView(for: pane))
        XCTAssertEqual(poolPublicationCount, 0)
        XCTAssertEqual(persistence.saveCount, baselineSaveCount)
    }

    func testSidebarIndicatorStaysInsideNarrowRowsAndUsesCompositorAnimation() async throws {
        let configurations: [(CGFloat, ColorScheme, Bool)] = [
            (240, .dark, false),
            (240, .light, true),
            (180, .dark, false),
            (140, .dark, false),
        ]

        for (width, scheme, selected) in configurations {
            let pane = TerminalPane(workingDirectory: "/tmp")
            let space = TerminalSpace(
                name: "A very long terminal space name that must truncate cleanly",
                layout: .terminal(pane)
            )
            let levelFour = WorkspaceFolder(name: "Level Four", children: [.space(space)])
            let levelThree = WorkspaceFolder(name: "Level Three", children: [.folder(levelFour)])
            let levelTwo = WorkspaceFolder(name: "Level Two", children: [.folder(levelThree)])
            let levelOne = WorkspaceFolder(name: "Level One", children: [.folder(levelTwo)])
            let selectedNote = ProjectNote(name: "Selected Note")
            let project = TerminalProject(
                name: "Long Project Name",
                rootDirectory: "/tmp",
                items: [.folder(levelOne), .note(selectedNote)],
                lastSelectedItemID: space.id,
                lastSelectedSpaceID: space.id
            )
            let document = WorkspaceDocument(
                projects: [project],
                selectedProjectID: project.id,
                selectedItemID: space.id,
                selectedSpaceID: space.id
            )
            let store = WorkspaceStore(
                persistence: StaticAgentWorkspacePersistence(document: document)
            )
            store.selectSpace(withID: space.id, inProject: project.id)
            if !selected {
                store.selectNote(withID: selectedNote.id, inProject: project.id)
            }
            let registry = AgentActivityRegistry()
            registry.reconcile(topology: WorkspaceActivityTopology(document: store.document))
            let sessionID = UUID()
            registry.beginSession(paneID: pane.id, sessionID: sessionID)
            registry.setActivity(.active([.codex]), paneID: pane.id, sessionID: sessionID)

            let sidebar = ProjectSidebar(
                store: store,
                editors: EditorSessionPool(store: store),
                notes: NoteSessionPool(persistence: EmptyAgentNotePersistence()),
                agentActivity: registry,
                activityIndicatorsVisible: true,
                chooseProject: {},
                hideSidebar: {}
            )
            .environment(\.colorScheme, scheme)
            .frame(width: width, height: 360)
            let hostingView = NSHostingView(rootView: sidebar)
            hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 360)
            let window = NSWindow(
                contentRect: hostingView.bounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            for _ in 0..<3 {
                await Task.yield()
                try await Task.sleep(nanoseconds: 20_000_000)
                hostingView.layoutSubtreeIfNeeded()
            }

            let glyphViews = descendants(of: hostingView).filter {
                String(describing: type(of: $0)).contains("AgentActivityGlyphView")
            }
            let activeGlyph = try XCTUnwrap(
                glyphViews.first { view in
                    view.layer?.sublayers?.first?.opacity ?? 0 > 0.5
                }
            )
            let frame = activeGlyph.convert(activeGlyph.bounds, to: hostingView)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, width - 5.5)
            XCTAssertEqual(frame.width, 14, accuracy: 0.5)
            XCTAssertTrue(
                activeGlyph.layer?.sublayers?.dropFirst().contains { layer in
                    layer.animation(forKey: "termuctive-dot-tail") != nil
                } == true
            )

            let attachment = XCTAttachment(image: try renderedImage(of: hostingView))
            attachment.name = "Agent activity \(Int(width))pt \(scheme) selected \(selected)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let pane = TerminalPane(workingDirectory: "/tmp")
        let space = TerminalSpace(name: "Reduced Motion", layout: .terminal(pane))
        let project = TerminalProject(
            name: "Activity",
            rootDirectory: "/tmp",
            items: [.space(space)]
        )
        let registry = AgentActivityRegistry()
        registry.reconcile(
            topology: WorkspaceActivityTopology(
                document: WorkspaceDocument(projects: [project])
            )
        )
        let sessionID = UUID()
        registry.beginSession(paneID: pane.id, sessionID: sessionID)
        registry.setActivity(.active([.codex]), paneID: pane.id, sessionID: sessionID)
        XCTAssertEqual(
            registry.signal(for: .space(space.id)).summary.accessibilityValue,
            "Codex active"
        )

        let reducedMotionSidebar = AgentActivityStatusSlot(
            registry: registry,
            scope: .space(space.id),
            isPresented: true,
            isVisible: true,
            selected: false,
            reduceMotionOverride: true
        )
        .frame(width: 14, height: 14)
        let reducedMotionView = NSHostingView(rootView: reducedMotionSidebar)
        reducedMotionView.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
        await Task.yield()
        reducedMotionView.layoutSubtreeIfNeeded()
        let reducedMotionGlyphs = descendants(of: reducedMotionView).filter {
            String(describing: type(of: $0)).contains("AgentActivityGlyphView")
        }
        XCTAssertFalse(
            reducedMotionGlyphs.contains { view in
                view.layer?.sublayers?.contains { layer in
                    layer.animation(forKey: "termuctive-dot-tail") != nil
                } == true
            }
        )
    }

    private func fixtureExecutable(named name: String) throws -> URL {
        let url = Bundle.main
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: url.path),
            "Missing executable fixture at \(url.path)"
        )
        return url
    }

    private func processRecord(
        path: String,
        processName: String = "",
        arguments: [String] = []
    ) -> AgentProcessRecord {
        AgentProcessRecord(
            processID: 1,
            executablePath: path,
            processName: processName,
            arguments: arguments
        )
    }

    private func shellIdentity(processID: Int32) -> AgentShellIdentity {
        AgentShellIdentity(
            processID: processID,
            startSeconds: UInt64(processID),
            startMicroseconds: UInt64(processID) + 1
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
        throw AgentActivityTestError.timedOut
    }

    private func terminalOutput(_ terminal: TermuctiveTerminalView) -> String {
        String(
            decoding: terminal.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func renderedImage(of view: NSView) throws -> NSImage {
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

private enum AgentActivityTestError: Error {
    case timedOut
}

private final class LockedAgentProcessInspector: AgentProcessInspecting {
    private let lock = NSLock()
    private var storedIdentity: AgentShellIdentity?
    private var storedInspection: AgentProcessInspection

    var identity: AgentShellIdentity? {
        get {
            lock.withLock { storedIdentity }
        }
        set {
            lock.withLock { storedIdentity = newValue }
        }
    }

    var inspection: AgentProcessInspection {
        get {
            lock.withLock { storedInspection }
        }
        set {
            lock.withLock { storedInspection = newValue }
        }
    }

    init(identity: AgentShellIdentity?, inspection: AgentProcessInspection) {
        storedIdentity = identity
        storedInspection = inspection
    }

    func shellIdentity(shellPID: Int32) -> AgentShellIdentity? {
        identity
    }

    func inspect(
        shellPID: Int32,
        expectedIdentity: AgentShellIdentity
    ) -> AgentProcessInspection {
        inspection
    }
}

private final class CountingAgentProcessInspector: AgentProcessInspecting {
    private let lock = NSLock()
    private var inspections: [Int32: AgentProcessInspection]
    private var counts: [Int32: Int] = [:]

    init(inspections: [Int32: AgentProcessInspection]) {
        self.inspections = inspections
    }

    func shellIdentity(shellPID: Int32) -> AgentShellIdentity? {
        lock.withLock {
            guard case .snapshot(let snapshot) = inspections[shellPID] else {
                return nil
            }
            return snapshot.shellIdentity
        }
    }

    func inspect(
        shellPID: Int32,
        expectedIdentity: AgentShellIdentity
    ) -> AgentProcessInspection {
        lock.withLock {
            counts[shellPID, default: 0] += 1
            return inspections[shellPID] ?? .unavailable
        }
    }

    func setInspection(_ inspection: AgentProcessInspection, for shellPID: Int32) {
        lock.withLock {
            inspections[shellPID] = inspection
        }
    }

    func inspectionCount(for shellPID: Int32) -> Int {
        lock.withLock { counts[shellPID, default: 0] }
    }

    func resetCounts() {
        lock.withLock {
            counts.removeAll()
        }
    }
}

private final class CountingAgentWorkspacePersistence: WorkspacePersisting {
    private(set) var saveCount = 0

    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {
        saveCount += 1
    }
}

private final class StaticAgentWorkspacePersistence: WorkspacePersisting {
    let document: WorkspaceDocument

    init(document: WorkspaceDocument) {
        self.document = document
    }

    func load() throws -> WorkspaceDocument? {
        document
    }

    func save(_ document: WorkspaceDocument) throws {}
}

private struct EmptyAgentNotePersistence: NotePersisting {
    func load(noteID: UUID) throws -> NoteDocument? {
        nil
    }

    func save(_ document: NoteDocument) throws {}

    func archive(noteID: UUID) throws {}
}
