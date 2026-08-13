import Foundation
import XCTest

@testable import Termuctive

@MainActor
final class EditorSessionPoolTests: XCTestCase {
    func testReturningToTerminalRetainsOpenBuffersAndUnsavedEdits() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let store = WorkspaceStore(persistence: EditorPoolTestPersistence())
        store.addProject(at: directory)
        let paneID = try XCTUnwrap(store.focusedPaneID)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
        }

        editors.presentEditor(inPaneID: paneID)
        let originalSession = try XCTUnwrap(editors.session(forPaneID: paneID))
        await originalSession.openFile(fileURL)
        let buffer = try XCTUnwrap(originalSession.selectedBuffer)
        buffer.updateText("let value = 2\n")
        XCTAssertTrue(originalSession.isFileActivityRunning)

        editors.dismissEditor(inPaneID: paneID)
        XCTAssertFalse(editors.isEditorPresented(inPaneID: paneID))
        XCTAssertFalse(originalSession.isFileActivityRunning)
        editors.presentEditor(inPaneID: paneID)

        let restoredSession = try XCTUnwrap(editors.session(forPaneID: paneID))
        XCTAssertTrue(restoredSession === originalSession)
        XCTAssertTrue(restoredSession.selectedBuffer === buffer)
        XCTAssertEqual(restoredSession.selectedBuffer?.text, "let value = 2\n")
        XCTAssertTrue(restoredSession.hasUnsavedChanges)
        XCTAssertTrue(restoredSession.isFileActivityRunning)
    }

    func testHiddenSpacePausesRetainedEditorFileActivity() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = WorkspaceStore(persistence: EditorPoolTestPersistence())
        store.addProject(at: directory)
        let firstPaneID = try XCTUnwrap(store.focusedPaneID)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
        }

        editors.presentEditor(inPaneID: firstPaneID)
        let firstSession = try XCTUnwrap(editors.session(forPaneID: firstPaneID))
        editors.setVisiblePaneIDs([firstPaneID])
        XCTAssertTrue(firstSession.isFileActivityRunning)

        store.addSpace()
        let secondPaneID = try XCTUnwrap(store.focusedPaneID)
        editors.setVisiblePaneIDs([secondPaneID])

        XCTAssertFalse(firstSession.isFileActivityRunning)
        XCTAssertTrue(editors.isEditorPresented(inPaneID: firstPaneID))

        editors.setVisiblePaneIDs([firstPaneID])

        XCTAssertTrue(firstSession.isFileActivityRunning)
    }

    func testZoomPausesEditorsThatAreNotActuallyRendered() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = WorkspaceStore(persistence: EditorPoolTestPersistence())
        store.addProject(at: directory)
        let firstPaneID = try XCTUnwrap(store.focusedPaneID)
        store.splitFocusedPane(axis: .horizontal)
        let secondPaneID = try XCTUnwrap(store.focusedPaneID)
        let activity = AgentActivityRegistry()
        let sessions = TerminalSessionPool(
            store: store,
            agentActivityRegistry: activity
        )
        let editors = EditorSessionPool(store: store)
        let notes = NoteSessionPool()
        defer {
            notes.terminateAll()
            editors.terminateAll()
            sessions.terminateAll()
        }
        editors.presentEditor(inPaneID: firstPaneID)
        editors.presentEditor(inPaneID: secondPaneID)
        let firstSession = try XCTUnwrap(editors.session(forPaneID: firstPaneID))
        let secondSession = try XCTUnwrap(editors.session(forPaneID: secondPaneID))
        let workspace = WorkspaceView(
            store: store,
            sessions: sessions,
            editors: editors,
            notes: notes,
            appearance: AppearanceSettings(),
            agentActivity: activity
        )

        XCTAssertEqual(workspace.renderedEditorPaneIDs, [firstPaneID, secondPaneID])

        store.focusPane(withID: firstPaneID)
        store.toggleFocusedPaneZoom()
        editors.setVisiblePaneIDs(workspace.renderedEditorPaneIDs)

        XCTAssertEqual(workspace.renderedEditorPaneIDs, [firstPaneID])
        XCTAssertTrue(firstSession.isFileActivityRunning)
        XCTAssertFalse(secondSession.isFileActivityRunning)
    }

    func testClosingPaneWithUnsavedEditorChangesRequiresConfirmation() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let store = WorkspaceStore(persistence: EditorPoolTestPersistence())
        store.addProject(at: directory)
        let paneID = try XCTUnwrap(store.focusedPaneID)
        let spaceID = try XCTUnwrap(store.selectedSpace?.id)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
        }

        editors.presentEditor(inPaneID: paneID)
        let session = try XCTUnwrap(editors.session(forPaneID: paneID))
        await session.openFile(fileURL)
        session.selectedBuffer?.updateText("let value = 2\n")

        editors.requestClosePane(withID: paneID)

        XCTAssertEqual(editors.pendingClosePaneID, paneID)
        XCTAssertEqual(store.selectedSpace?.id, spaceID)
        XCTAssertTrue(store.document.terminalIDs.contains(paneID))

        editors.discardAndClosePendingPane()

        XCTAssertNil(editors.pendingClosePaneID)
        XCTAssertFalse(store.document.terminalIDs.contains(paneID))
        XCTAssertNil(editors.retainedSession(forPaneID: paneID))
    }

    func testDiscardingPendingUnsavedPaneCloseAfterSwitchingTabsClosesOriginalPane()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let store = WorkspaceStore(persistence: EditorPoolTestPersistence())
        store.addProject(at: directory)
        let firstSpaceID = try XCTUnwrap(store.selectedSpace?.id)
        let firstPaneID = try XCTUnwrap(store.focusedPaneID)
        store.addSpace()
        let secondSpaceID = try XCTUnwrap(store.selectedSpace?.id)
        let secondPaneID = try XCTUnwrap(store.focusedPaneID)
        store.selectTerminalSpaceTab(withID: firstSpaceID)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
        }

        editors.presentEditor(inPaneID: firstPaneID)
        let firstSession = try XCTUnwrap(editors.session(forPaneID: firstPaneID))
        await firstSession.openFile(fileURL)
        firstSession.selectedBuffer?.updateText("let value = 2\n")
        editors.requestClosePane(withID: firstPaneID)
        store.selectTerminalSpaceTab(withID: secondSpaceID)

        XCTAssertEqual(editors.pendingClosePaneID, firstPaneID)
        XCTAssertEqual(store.document.selectedSpaceID, secondSpaceID)
        XCTAssertTrue(store.document.terminalIDs.contains(firstPaneID))

        editors.discardAndClosePendingPane()

        XCTAssertNil(editors.pendingClosePaneID)
        XCTAssertNil(editors.retainedSession(forPaneID: firstPaneID))
        XCTAssertFalse(store.document.terminalIDs.contains(firstPaneID))
        XCTAssertNil(store.document.space(withID: firstSpaceID))
        XCTAssertEqual(store.document.selectedSpaceID, secondSpaceID)
        XCTAssertEqual(store.focusedPaneID, secondPaneID)
        XCTAssertTrue(store.document.terminalIDs.contains(secondPaneID))
        XCTAssertEqual(try String(contentsOf: fileURL), "let value = 1\n")
    }

    func testSavingPendingUnsavedPaneCloseAfterSwitchingTabsClosesOriginalPane()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let store = WorkspaceStore(persistence: EditorPoolTestPersistence())
        store.addProject(at: directory)
        let firstSpaceID = try XCTUnwrap(store.selectedSpace?.id)
        let firstPaneID = try XCTUnwrap(store.focusedPaneID)
        store.addSpace()
        let secondSpaceID = try XCTUnwrap(store.selectedSpace?.id)
        let secondPaneID = try XCTUnwrap(store.focusedPaneID)
        store.selectTerminalSpaceTab(withID: firstSpaceID)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
        }

        editors.presentEditor(inPaneID: firstPaneID)
        let firstSession = try XCTUnwrap(editors.session(forPaneID: firstPaneID))
        await firstSession.openFile(fileURL)
        firstSession.selectedBuffer?.updateText("let value = 2\n")
        editors.requestClosePane(withID: firstPaneID)
        store.selectTerminalSpaceTab(withID: secondSpaceID)

        await editors.saveAndClosePendingPane()

        XCTAssertNil(editors.pendingClosePaneID)
        XCTAssertNil(editors.retainedSession(forPaneID: firstPaneID))
        XCTAssertFalse(store.document.terminalIDs.contains(firstPaneID))
        XCTAssertNil(store.document.space(withID: firstSpaceID))
        XCTAssertEqual(store.document.selectedSpaceID, secondSpaceID)
        XCTAssertEqual(store.focusedPaneID, secondPaneID)
        XCTAssertTrue(store.document.terminalIDs.contains(secondPaneID))
        XCTAssertEqual(try String(contentsOf: fileURL), "let value = 2\n")
    }

    func testAggregateUnsavedStateAndScopedSaveCoverRetainedSessions() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let store = WorkspaceStore(persistence: EditorPoolTestPersistence())
        store.addProject(at: directory)
        let paneID = try XCTUnwrap(store.focusedPaneID)
        let editors = EditorSessionPool(store: store)
        defer {
            editors.terminateAll()
        }

        editors.presentEditor(inPaneID: paneID)
        let session = try XCTUnwrap(editors.session(forPaneID: paneID))
        await session.openFile(fileURL)
        session.selectedBuffer?.updateText("let value = 2\n")
        editors.dismissEditor(inPaneID: paneID)

        XCTAssertTrue(editors.hasUnsavedChanges)
        XCTAssertTrue(editors.hasUnsavedChanges(inPaneIDs: [paneID]))
        XCTAssertFalse(editors.hasUnsavedChanges(inPaneIDs: [UUID()]))

        try await editors.saveAllBuffers(inPaneIDs: [paneID])

        XCTAssertFalse(editors.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: fileURL), "let value = 2\n")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "termuctive-editor-pool-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

private final class EditorPoolTestPersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
