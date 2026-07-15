import XCTest

@testable import Termuctive

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testAddingProjectCreatesAndPersistsInitialTerminalSpace() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        let url = URL(fileURLWithPath: "/tmp/termuctive-project")

        store.addProject(at: url)

        let focusedPaneID = try XCTUnwrap(store.focusedPaneID)
        XCTAssertEqual(store.document.projects.count, 1)
        XCTAssertEqual(store.selectedProject?.name, "termuctive-project")
        XCTAssertEqual(store.selectedSpace?.name, "Terminal")
        XCTAssertEqual(
            store.selectedSpace?.layout.terminal(withID: focusedPaneID)?.workingDirectory,
            url.path
        )
        XCTAssertEqual(persistence.savedDocuments.last, store.document)
    }

    func testAddingSameProjectTwiceDoesNotDuplicateIt() {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        let url = URL(fileURLWithPath: "/tmp/termuctive-project")

        store.addProject(at: url)
        store.addProject(at: url)

        XCTAssertEqual(store.document.projects.count, 1)
    }

    func testSpaceCanBeAddedInsideSelectedFolder() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))

        store.addFolder()
        let folderID = try XCTUnwrap(store.selectedFolderID)
        store.addSpace()

        let project = try XCTUnwrap(store.selectedProject)
        guard case .folder(let folder) = project.items.last else {
            return XCTFail("Expected a root folder.")
        }
        XCTAssertEqual(folder.id, folderID)
        XCTAssertEqual(folder.children.count, 1)
        guard case .space(let space) = folder.children[0] else {
            return XCTFail("Expected a terminal space inside the folder.")
        }
        XCTAssertEqual(store.document.selectedSpaceID, space.id)
    }

    func testSplitAndCloseRestoreSinglePaneLayout() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let originalPaneID = try XCTUnwrap(store.focusedPaneID)

        store.splitFocusedPane(axis: .vertical)

        XCTAssertEqual(store.selectedSpace?.layout.terminalCount, 2)
        XCTAssertNotEqual(store.focusedPaneID, originalPaneID)
        XCTAssertTrue(store.canCloseFocusedPane)

        store.closeFocusedPane()

        XCTAssertEqual(store.selectedSpace?.layout.terminalCount, 1)
        XCTAssertEqual(store.focusedPaneID, originalPaneID)
        XCTAssertFalse(store.canCloseFocusedPane)
    }

    func testFolderExpansionTogglesExactlyOnce() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        store.addFolder()
        let folderID = try XCTUnwrap(store.selectedFolderID)
        let projectID = try XCTUnwrap(store.selectedProject?.id)

        XCTAssertTrue(store.expandedFolderIDs.contains(folderID))

        store.toggleFolder(withID: folderID)
        store.selectFolder(withID: folderID, inProject: projectID)

        XCTAssertFalse(store.expandedFolderIDs.contains(folderID))
        XCTAssertEqual(store.selectedFolderID, folderID)
    }

    func testHiddenTerminalDirectoryUpdatePersistsOnlyWhenChanged() throws {
        let visiblePane = TerminalPane(workingDirectory: "/visible")
        let visibleSpace = TerminalSpace(
            name: "Visible",
            layout: .terminal(visiblePane)
        )
        let visibleProject = TerminalProject(
            name: "Visible",
            rootDirectory: "/visible",
            items: [.space(visibleSpace)]
        )
        let hiddenPane = TerminalPane(workingDirectory: "/hidden")
        let hiddenSpace = TerminalSpace(
            name: "Hidden",
            layout: .terminal(hiddenPane)
        )
        let hiddenProject = TerminalProject(
            name: "Hidden",
            rootDirectory: "/hidden",
            items: [.folder(WorkspaceFolder(name: "Nested", children: [.space(hiddenSpace)]))]
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [visibleProject, hiddenProject],
            selectedProjectID: visibleProject.id,
            selectedSpaceID: visibleSpace.id
        )
        let store = WorkspaceStore(persistence: persistence)

        store.updateTerminal(
            paneID: hiddenPane.id,
            workingDirectory: "/hidden/service"
        )

        XCTAssertEqual(store.document.selectedProjectID, visibleProject.id)
        XCTAssertEqual(
            store.document.terminal(withID: hiddenPane.id)?.workingDirectory,
            "/hidden/service"
        )
        XCTAssertEqual(persistence.savedDocuments.count, 1)

        store.updateTerminal(
            paneID: hiddenPane.id,
            workingDirectory: "/hidden/service"
        )

        XCTAssertEqual(persistence.savedDocuments.count, 1)
    }
}

private final class RecordingPersistence: WorkspacePersisting {
    var loadedDocument: WorkspaceDocument?
    var savedDocuments: [WorkspaceDocument] = []

    func load() throws -> WorkspaceDocument? {
        loadedDocument
    }

    func save(_ document: WorkspaceDocument) throws {
        savedDocuments.append(document)
    }
}
