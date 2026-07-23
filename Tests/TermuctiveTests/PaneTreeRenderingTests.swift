import AppKit
import PDFKit
import XCTest

@testable import Termuctive

@MainActor
final class PaneTreeRenderingTests: XCTestCase {
    func testTerminalViewsRemainAttachedAcrossSplitAndClose() async throws {
        let persistence = PaneTreeTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let initialPane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(
                withID: try XCTUnwrap(store.focusedPaneID)
            )
        )
        let sessions = TerminalSessionPool(store: store)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
            sessions.terminateAll()
        }
        let container = PaneTreeContainerView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()
        await Task.yield()
        let initialTerminalView = sessions.terminalView(for: initialPane)
        XCTAssertTrue(initialTerminalView.isDescendant(of: container))

        store.splitFocusedPane(axis: .horizontal)
        let addedPane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(
                withID: try XCTUnwrap(store.focusedPaneID)
            )
        )
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()
        await Task.yield()
        let addedTerminalView = sessions.terminalView(for: addedPane)
        XCTAssertTrue(initialTerminalView.isDescendant(of: container))
        XCTAssertTrue(addedTerminalView.isDescendant(of: container))

        store.closeFocusedPane()
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()
        await Task.yield()
        XCTAssertTrue(initialTerminalView.isDescendant(of: container))
    }

    func testPDFPreviewDetachesAndRestoresTheExistingTerminalView() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("termuctive-pdf-pane-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let persistence = PaneTreeTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: directory)
        let leftPaneID = try XCTUnwrap(store.focusedPaneID)
        store.splitFocusedPane(axis: .horizontal)
        let orderedPaneIDs = try XCTUnwrap(store.selectedSpace?.layout.orderedTerminalIDs)
        XCTAssertEqual(orderedPaneIDs.count, 2)
        let rightPaneID = try XCTUnwrap(orderedPaneIDs.last)
        let leftPane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: leftPaneID)
        )
        let rightPane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: rightPaneID)
        )

        let sessions = TerminalSessionPool(store: store)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
            sessions.terminateAll()
        }
        let container = PaneTreeContainerView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()
        await Task.yield()

        let leftTerminalView = sessions.terminalView(for: leftPane)
        let rightTerminalView = sessions.terminalView(for: rightPane)
        XCTAssertTrue(leftTerminalView.isDescendant(of: container))
        XCTAssertTrue(rightTerminalView.isDescendant(of: container))

        let pdfURL = directory.appendingPathComponent("latest-session-output.pdf")
        try makeTestPDF(at: pdfURL)
        sessions.moveRecentPDF(fromPaneID: leftPaneID, placement: .right)
        try await waitUntil {
            sessions.previewURL(for: rightPaneID) == pdfURL.standardizedFileURL
        }

        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        try await waitUntil {
            !rightTerminalView.isDescendant(of: container)
        }
        XCTAssertTrue(leftTerminalView.isDescendant(of: container))

        sessions.dismissPDFPreview(inPaneID: rightPaneID)
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        try await waitUntil {
            rightTerminalView.isDescendant(of: container)
        }
        XCTAssertTrue(sessions.terminalView(for: rightPane) === rightTerminalView)
        XCTAssertTrue(window.firstResponder === rightTerminalView)
    }

    func testTerminalWritesAppearInSplitIDEAndEditorSavePreservesBothTerminals() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "termuctive-ide-pane-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let persistence = PaneTreeTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: directory)
        let leftPaneID = try XCTUnwrap(store.focusedPaneID)
        store.splitFocusedPane(axis: .horizontal)
        let rightPaneID = try XCTUnwrap(store.focusedPaneID)
        let leftPane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: leftPaneID)
        )
        let rightPane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: rightPaneID)
        )
        let sessions = TerminalSessionPool(store: store)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
            sessions.terminateAll()
        }

        let container = PaneTreeContainerView(
            frame: NSRect(x: 0, y: 0, width: 920, height: 620)
        )
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()
        let leftTerminal = sessions.terminalView(for: leftPane)
        let rightTerminal = sessions.terminalView(for: rightPane)
        try await waitUntil {
            leftTerminal.isDescendant(of: container)
                && rightTerminal.isDescendant(of: container)
        }

        editors.presentEditor(inPaneID: rightPaneID)
        let editorSession = try XCTUnwrap(editors.session(forPaneID: rightPaneID))
        await editorSession.openFile(fileURL)
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()

        try await waitUntil {
            leftTerminal.isDescendant(of: container)
                && !rightTerminal.isDescendant(of: container)
                && self.firstSubview(of: SourceTextView.self, in: container) != nil
        }
        let buffer = try XCTUnwrap(editorSession.selectedBuffer)

        leftTerminal.send(
            txt: "printf 'let value = 2\\n' > '\(fileURL.path)'\n"
        )
        try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            buffer.text == "let value = 2\n"
        }

        buffer.updateText("let value = 3\n")
        try await buffer.save()
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: fileURL), as: UTF8.self),
            "let value = 3\n"
        )

        editors.dismissEditor(inPaneID: rightPaneID)
        sessions.focus(paneID: rightPaneID)
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        try await waitUntil {
            leftTerminal.isDescendant(of: container)
                && rightTerminal.isDescendant(of: container)
        }
        XCTAssertTrue(sessions.terminalView(for: leftPane) === leftTerminal)
        XCTAssertTrue(sessions.terminalView(for: rightPane) === rightTerminal)
        XCTAssertTrue(window.firstResponder === rightTerminal)
    }

    func testPDFTemporarilyOverlaysIDEAndReturnsToTheSameEditorSession() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "termuctive-ide-pdf-pane-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: directory)
        }
        let sourceURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: sourceURL)

        let store = WorkspaceStore(persistence: PaneTreeTestPersistence())
        store.addProject(at: directory)
        let leftPaneID = try XCTUnwrap(store.focusedPaneID)
        store.splitFocusedPane(axis: .horizontal)
        let rightPaneID = try XCTUnwrap(store.focusedPaneID)
        let leftPane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: leftPaneID)
        )
        let rightPane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: rightPaneID)
        )
        let sessions = TerminalSessionPool(store: store)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
            sessions.terminateAll()
        }
        let leftTerminal = sessions.terminalView(for: leftPane)
        let rightTerminal = sessions.terminalView(for: rightPane)

        let container = PaneTreeContainerView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        editors.presentEditor(inPaneID: rightPaneID)
        let editorSession = try XCTUnwrap(editors.session(forPaneID: rightPaneID))
        await editorSession.openFile(sourceURL)
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()
        try await waitUntil {
            leftTerminal.isDescendant(of: container)
                && !rightTerminal.isDescendant(of: container)
                && self.firstSubview(of: SourceTextView.self, in: container) != nil
        }

        let pdfURL = directory.appendingPathComponent("architecture.pdf")
        try makeTestPDF(at: pdfURL)
        sessions.moveRecentPDF(fromPaneID: leftPaneID, placement: .right)
        try await waitUntil {
            sessions.previewURL(for: rightPaneID) == pdfURL.standardizedFileURL
        }
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        try await waitUntil {
            self.firstSubview(of: PDFView.self, in: container) != nil
                && self.firstSubview(of: SourceTextView.self, in: container) == nil
        }

        sessions.dismissPDFPreview(inPaneID: rightPaneID)
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        try await waitUntil {
            self.firstSubview(of: SourceTextView.self, in: container) != nil
        }
        XCTAssertTrue(editors.session(forPaneID: rightPaneID) === editorSession)
        XCTAssertEqual(editorSession.selectedBuffer?.url, sourceURL)
        XCTAssertTrue(sessions.terminalView(for: rightPane) === rightTerminal)
    }

    func testSwitchingSpacesKeepsHiddenTerminalAtItsSettledSize() async throws {
        let persistence = PaneTreeTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let projectID = try XCTUnwrap(store.document.selectedProjectID)
        let firstSpaceID = try XCTUnwrap(store.document.selectedSpaceID)
        let firstLayout = try XCTUnwrap(store.selectedSpace?.layout)
        let firstPane = try XCTUnwrap(
            firstLayout.terminal(withID: firstLayout.firstTerminalID)
        )
        let sessions = TerminalSessionPool(store: store)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
            sessions.terminateAll()
        }
        let container = PaneTreeContainerView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()

        let firstTerminal = sessions.terminalView(for: firstPane)
        try await waitUntil {
            firstTerminal.frame.width > 0 && firstTerminal.frame.height > 0
        }
        let settledSize = firstTerminal.frame.size

        store.addSpace()
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(firstTerminal.frame.size, settledSize)
        XCTAssertFalse(firstTerminal.isDescendant(of: container))

        container.setFrameSize(NSSize(width: 820, height: 560))
        container.layoutSubtreeIfNeeded()
        store.selectSpace(withID: firstSpaceID, inProject: projectID)
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions,
            editors: editors
        )
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(firstTerminal.frame.size, settledSize)
        try await waitUntil {
            firstTerminal.frame.size != settledSize
        }
        XCTAssertTrue(firstTerminal.isDescendant(of: container))
    }

    private func makeTestPDF(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: url))
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - startedAt >= timeoutNanoseconds {
                XCTFail("Timed out waiting for the expected pane state.")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class PaneTreeTestPersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
