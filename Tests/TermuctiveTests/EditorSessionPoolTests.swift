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

        editors.dismissEditor(inPaneID: paneID)
        XCTAssertFalse(editors.isEditorPresented(inPaneID: paneID))
        editors.presentEditor(inPaneID: paneID)

        let restoredSession = try XCTUnwrap(editors.session(forPaneID: paneID))
        XCTAssertTrue(restoredSession === originalSession)
        XCTAssertTrue(restoredSession.selectedBuffer === buffer)
        XCTAssertEqual(restoredSession.selectedBuffer?.text, "let value = 2\n")
        XCTAssertTrue(restoredSession.hasUnsavedChanges)
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
