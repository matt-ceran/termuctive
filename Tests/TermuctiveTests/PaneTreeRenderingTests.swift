import AppKit
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
}

private final class PaneTreeTestPersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
