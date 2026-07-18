import AppKit
import Combine
import Metal
import SwiftTerm
import XCTest

@testable import Termuctive

@MainActor
final class TerminalEngineIntegrationTests: XCTestCase {
    func testTermuctiveSessionAcceptsInteractiveInput() async throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        terminal.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let marker = "TERMUCTIVE_INTERACTIVE_\(UUID().uuidString.prefix(8))"
        terminal.send(txt: "printf '\(marker)\\n'\n")

        let output = try await terminalOutput(
            from: terminal,
            containing: [marker],
            timeout: 5
        )
        XCTAssertTrue(
            output.contains(marker),
            "Terminal output was \(output.debugDescription)"
        )
    }

    func testFocusRequestedBeforeAttachmentIsAppliedAfterAttachment() async throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        sessions.focus(paneID: pane.id)
        XCTAssertNil(terminal.window)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === terminal)
    }

    func testAttachedTerminalUsesAcceleratedRendererWhenMetalIsAvailable() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)

        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertTrue(terminal.isUsingMetalRenderer)
        }
    }

    func testTerminalFontSizeStartsCompactAndStaysWithinBounds() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        XCTAssertEqual(terminal.font.pointSize, 11)
        sessions.increaseFontSize()
        XCTAssertEqual(terminal.font.pointSize, 12)
        sessions.decreaseFontSize()
        XCTAssertEqual(terminal.font.pointSize, 11)

        for _ in 0..<40 {
            sessions.decreaseFontSize()
        }
        XCTAssertEqual(terminal.font.pointSize, 8)
        XCTAssertFalse(sessions.canDecreaseFontSize)

        for _ in 0..<40 {
            sessions.increaseFontSize()
        }
        XCTAssertEqual(terminal.font.pointSize, 32)
        XCTAssertFalse(sessions.canIncreaseFontSize)
    }

    func testTerminalUsesStandardMacOSFontSmoothing() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        XCTAssertTrue(terminal.fontSmoothing)
    }

    func testInteractivePaneResizeCommitsOneSettledPTYSize() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let processDelegate = TerminalResizeTestDelegate()
        terminal.processDelegate = processDelegate
        terminal.startProcess(executable: "/bin/sh")
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }

        let initialSize = terminal.frame.size
        terminal.beginInteractivePaneResize()
        for width in stride(from: 600, through: 440, by: -20) {
            terminal.setFrameSize(
                NSSize(width: CGFloat(width), height: 420)
            )
        }

        XCTAssertEqual(terminal.frame.size, initialSize)
        XCTAssertEqual(processDelegate.resizeEvents.count, 0)

        terminal.endInteractivePaneResize()

        XCTAssertEqual(terminal.frame.size, NSSize(width: 440, height: 420))
        XCTAssertEqual(processDelegate.resizeEvents.count, 1)
    }

    func testOverlappingResizeTransactionsWaitForEveryTransition() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let processDelegate = TerminalResizeTestDelegate()
        terminal.processDelegate = processDelegate
        terminal.startProcess(executable: "/bin/sh")
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }

        terminal.beginInteractivePaneResize(reason: .animatedLayout)
        terminal.beginInteractivePaneResize(reason: .divider)
        terminal.setFrameSize(NSSize(width: 500, height: 400))
        terminal.endInteractivePaneResize(reason: .divider)

        XCTAssertEqual(terminal.frame.size, NSSize(width: 640, height: 480))
        XCTAssertEqual(processDelegate.resizeEvents.count, 0)

        terminal.endInteractivePaneResize(reason: .animatedLayout)

        XCTAssertEqual(terminal.frame.size, NSSize(width: 500, height: 400))
        XCTAssertEqual(processDelegate.resizeEvents.count, 1)
    }

    func testMovePDFPrefersLatestVisibleCodexPathOverStaleDetection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termuctive-visible-pdf-\(UUID().uuidString)")
        let outputDirectory = directory.appendingPathComponent("output/pdf", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let stalePDF = directory.appendingPathComponent("old-report.pdf")
        let visiblePDF = outputDirectory.appendingPathComponent(
            "biohub_phase9_appearance_cnn_foundation.pdf"
        )
        try Data("%PDF-stale".utf8).write(to: stalePDF)
        try Data("%PDF-visible".utf8).write(to: visiblePDF)

        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: directory)
        let sourcePaneID = try XCTUnwrap(store.focusedPaneID)
        let sourcePane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: sourcePaneID)
        )
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: sourcePane)
        defer {
            sessions.terminateAll()
        }
        terminal.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        terminal.dataReceived(
            slice: Array("Previously opened \(stalePDF.path)\n".utf8)[...]
        )
        terminal.dataReceived(
            slice: Array("Opened latest Biohub PDF: output/pdf/biohub_phase9_X".utf8)[...]
        )
        terminal.dataReceived(
            slice: Array("\u{8}appearance_cnn_foundation.pdf. It is 14 pages.\n".utf8)[...]
        )
        await Task.yield()

        let renderedOutput = String(
            decoding: terminal.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
        XCTAssertTrue(
            renderedOutput.contains("output/pdf/biohub_phase9_appearance_cnn_foundation.pdf")
        )

        store.splitFocusedPane(axis: .horizontal)
        let targetPaneID = try XCTUnwrap(store.selectedSpace?.layout.orderedTerminalIDs.last)
        sessions.moveRecentPDF(fromPaneID: sourcePaneID, placement: .right)

        XCTAssertEqual(
            sessions.previewURL(for: targetPaneID),
            visiblePDF.standardizedFileURL
        )
    }

    func testTerminalThemeChangesWithoutReplacingTheSessionView() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store, terminalTheme: .light)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        XCTAssertEqual(terminal.nativeBackgroundColor, TerminalTheme.light.backgroundColor)

        sessions.setTerminalTheme(.dark)

        XCTAssertTrue(terminal === sessions.terminalView(for: pane))
        XCTAssertEqual(terminal.nativeForegroundColor, TerminalTheme.dark.foregroundColor)
        XCTAssertEqual(terminal.nativeBackgroundColor, TerminalTheme.dark.backgroundColor)
    }

    func testCreatingTerminalSessionDoesNotPublishDuringViewConstruction() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        var publicationCount = 0
        let observation = sessions.objectWillChange.sink {
            publicationCount += 1
        }
        defer {
            observation.cancel()
            sessions.terminateAll()
        }

        _ = sessions.terminalView(for: pane)

        XCTAssertEqual(publicationCount, 0)
    }

    func testShellOutputAndWorkingDirectoryReachTerminalBuffer() async throws {
        let identifier = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("termuctive test \(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let expectedDirectory = directory.resolvingSymlinksInPath().path

        let terminal = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let processDelegate = TerminalTestDelegate(testCase: self)
        terminal.processDelegate = processDelegate
        terminal.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'TERMUCTIVE_PTY_OK\\n'; pwd"],
            currentDirectory: directory.path
        )

        await fulfillment(of: [processDelegate.terminated], timeout: 5)

        let output = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_PTY_OK", expectedDirectory],
            timeout: 2
        )
        XCTAssertTrue(
            output.contains("TERMUCTIVE_PTY_OK"),
            "Terminal output was \(output.debugDescription)"
        )
        XCTAssertTrue(
            output.contains(expectedDirectory),
            "Terminal output was \(output.debugDescription)"
        )
    }

    private func terminalOutput(
        from terminal: LocalProcessTerminalView,
        containing markers: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let data = terminal.getTerminal().getBufferAsData()
            let output = String(decoding: data, as: UTF8.self)
            if markers.allSatisfy({ output.contains($0) }) {
                return output
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return String(
            decoding: terminal.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
    }
}

private final class TerminalTestPersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}

private final class TerminalTestDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let terminated: XCTestExpectation

    init(testCase: XCTestCase) {
        terminated = testCase.expectation(description: "Shell process terminated")
    }

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminated.fulfill()
    }
}

private final class TerminalResizeTestDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private(set) var resizeEvents: [(columns: Int, rows: Int)] = []

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {
        resizeEvents.append((newCols, newRows))
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
