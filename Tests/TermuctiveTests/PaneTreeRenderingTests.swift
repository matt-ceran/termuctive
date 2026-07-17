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
        defer {
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
            sessions: sessions
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
            sessions: sessions
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
            sessions: sessions
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
        defer {
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
            sessions: sessions
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
            sessions: sessions
        )
        try await waitUntil {
            !rightTerminalView.isDescendant(of: container)
        }
        XCTAssertTrue(leftTerminalView.isDescendant(of: container))

        sessions.dismissPDFPreview(inPaneID: rightPaneID)
        container.configure(
            node: try XCTUnwrap(store.selectedSpace?.layout),
            store: store,
            sessions: sessions
        )
        try await waitUntil {
            rightTerminalView.isDescendant(of: container)
        }
        XCTAssertTrue(sessions.terminalView(for: rightPane) === rightTerminalView)
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
