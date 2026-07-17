import Combine
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

    func testSpaceCanBeAddedToExplicitFolderInAnotherProject() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/first"))
        let firstProjectID = try XCTUnwrap(store.selectedProject?.id)
        store.addFolder()
        let folderID = try XCTUnwrap(store.selectedFolderID)
        store.addProject(at: URL(fileURLWithPath: "/tmp/second"))

        store.addSpace(
            toFolderWithID: folderID,
            inProjectWithID: firstProjectID
        )

        let firstProject = try XCTUnwrap(
            store.document.projects.first { $0.id == firstProjectID }
        )
        guard case .folder(let folder) = firstProject.items.last,
            case .space(let space) = folder.children.last
        else {
            return XCTFail("Expected a terminal space inside the target folder.")
        }
        XCTAssertEqual(store.document.selectedProjectID, firstProjectID)
        XCTAssertEqual(store.document.selectedSpaceID, space.id)
        XCTAssertEqual(
            space.layout.terminal(withID: space.layout.firstTerminalID)?.workingDirectory,
            "/tmp/first")
        XCTAssertTrue(store.expandedFolderIDs.contains(folderID))
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
        XCTAssertTrue(store.canCloseFocusedPane)
    }

    func testPreparingLeftPDFPaneKeepsTheCommandTerminalFocused() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let commandPaneID = try XCTUnwrap(store.focusedPaneID)

        let pdfPaneID = try XCTUnwrap(
            store.preparePDFPane(
                fromPaneID: commandPaneID,
                placement: .left
            )
        )

        XCTAssertEqual(
            store.selectedSpace?.layout.orderedTerminalIDs,
            [pdfPaneID, commandPaneID]
        )
        XCTAssertEqual(store.focusedPaneID, commandPaneID)
    }

    func testSplitRatioCommitPersistsOnce() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        store.splitFocusedPane(axis: .horizontal)
        guard case .split(let split) = store.selectedSpace?.layout else {
            return XCTFail("Expected a split layout.")
        }
        persistence.savedDocuments.removeAll()
        var publicationCount = 0
        let observation = store.objectWillChange.sink {
            publicationCount += 1
        }
        defer {
            observation.cancel()
        }

        store.commitSplitRatio(splitID: split.id, ratio: 0.7)

        guard case .split(let resizedSplit) = store.selectedSpace?.layout else {
            return XCTFail("Expected the resized split layout.")
        }
        XCTAssertEqual(resizedSplit.ratio, 0.7)
        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testClosingPaneByIDPreservesAnotherFocusedPane() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let originalPaneID = try XCTUnwrap(store.focusedPaneID)
        store.splitFocusedPane(axis: .horizontal)
        store.splitFocusedPane(axis: .vertical)
        let focusedPaneID = try XCTUnwrap(store.focusedPaneID)

        store.closePane(withID: originalPaneID)

        XCTAssertEqual(store.selectedSpace?.layout.terminalCount, 2)
        XCTAssertFalse(
            store.selectedSpace?.layout.terminalIDs.contains(originalPaneID) ?? true
        )
        XCTAssertEqual(store.focusedPaneID, focusedPaneID)
    }

    func testClosingFinalPaneRemovesSpaceAndRestoresFallback() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let fallbackSpaceID = try XCTUnwrap(store.selectedSpace?.id)
        store.addSpace()
        let removedSpaceID = try XCTUnwrap(store.selectedSpace?.id)
        let removedPaneID = try XCTUnwrap(store.focusedPaneID)

        store.closePane(withID: removedPaneID)

        XCTAssertNil(store.selectedProject?.space(withID: removedSpaceID))
        XCTAssertEqual(store.document.selectedSpaceID, fallbackSpaceID)
        XCTAssertEqual(store.selectedProject?.terminalSpaces.count, 1)
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

    func testSwitchingProjectsRestoresEachProjectsLastSpace() throws {
        let firstPane = TerminalPane(workingDirectory: "/first")
        let secondPane = TerminalPane(workingDirectory: "/second")
        let firstSpace = TerminalSpace(name: "First", layout: .terminal(firstPane))
        let secondSpace = TerminalSpace(name: "Second", layout: .terminal(secondPane))
        let firstProject = TerminalProject(
            name: "One",
            rootDirectory: "/one",
            items: [.space(firstSpace), .space(secondSpace)],
            lastSelectedSpaceID: firstSpace.id
        )
        let otherPane = TerminalPane(workingDirectory: "/other")
        let otherSpace = TerminalSpace(name: "Other", layout: .terminal(otherPane))
        let otherProject = TerminalProject(
            name: "Two",
            rootDirectory: "/two",
            items: [.space(otherSpace)],
            lastSelectedSpaceID: otherSpace.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [firstProject, otherProject],
            selectedProjectID: firstProject.id,
            selectedSpaceID: firstSpace.id
        )
        let store = WorkspaceStore(persistence: persistence)

        store.selectSpace(withID: secondSpace.id, inProject: firstProject.id)
        store.selectProject(withID: otherProject.id)
        store.selectProject(withID: firstProject.id)

        XCTAssertEqual(store.document.selectedSpaceID, secondSpace.id)
        XCTAssertEqual(store.focusedPaneID, secondPane.id)
        XCTAssertEqual(store.selectedProject?.lastSelectedSpaceID, secondSpace.id)
    }

    func testProjectsExpandAndCollapseIndependently() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/one"))
        let firstProjectID = try XCTUnwrap(store.selectedProject?.id)
        store.addProject(at: URL(fileURLWithPath: "/tmp/two"))
        let secondProjectID = try XCTUnwrap(store.selectedProject?.id)

        XCTAssertEqual(store.expandedProjectIDs, [firstProjectID, secondProjectID])

        store.toggleProject(withID: firstProjectID)

        XCTAssertFalse(store.expandedProjectIDs.contains(firstProjectID))
        XCTAssertTrue(store.expandedProjectIDs.contains(secondProjectID))
        XCTAssertEqual(store.document.selectedProjectID, secondProjectID)

        store.toggleProject(withID: firstProjectID)
        store.selectProject(withID: firstProjectID)

        XCTAssertEqual(store.expandedProjectIDs, [firstProjectID, secondProjectID])
        XCTAssertEqual(persistence.savedDocuments.last, store.document)
    }

    func testRemovingSelectedNestedFolderRestoresRemainingSpace() throws {
        let fallbackPane = TerminalPane(workingDirectory: "/project")
        let fallbackSpace = TerminalSpace(
            name: "Fallback",
            layout: .terminal(fallbackPane)
        )
        let removedPane = TerminalPane(workingDirectory: "/project/removed")
        let removedSpace = TerminalSpace(
            name: "Removed",
            layout: .terminal(removedPane)
        )
        let folder = WorkspaceFolder(
            name: "Nested",
            children: [.space(removedSpace)]
        )
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(fallbackSpace), .folder(folder)],
            lastSelectedSpaceID: removedSpace.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: removedSpace.id
        )
        let store = WorkspaceStore(persistence: persistence)
        store.selectFolder(withID: folder.id, inProject: project.id)
        store.toggleFolder(withID: folder.id)

        store.removeItem(withID: folder.id, inProject: project.id)

        XCTAssertEqual(store.document.selectedSpaceID, fallbackSpace.id)
        XCTAssertEqual(store.focusedPaneID, fallbackPane.id)
        XCTAssertNil(store.selectedFolderID)
        XCTAssertFalse(store.expandedFolderIDs.contains(folder.id))
        XCTAssertFalse(store.document.terminalIDs.contains(removedPane.id))
        XCTAssertEqual(persistence.savedDocuments.count, 1)
    }

    func testRemovingSelectedProjectsChoosesNeighborThenClearsSelection() {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/one"))
        let firstProjectID = store.document.projects[0].id
        store.addProject(at: URL(fileURLWithPath: "/tmp/two"))
        let secondProjectID = store.document.projects[1].id
        persistence.savedDocuments.removeAll()

        store.selectProject(withID: firstProjectID)
        persistence.savedDocuments.removeAll()
        store.removeProject(withID: firstProjectID)

        XCTAssertEqual(store.document.selectedProjectID, secondProjectID)
        XCTAssertNotNil(store.document.selectedSpaceID)

        store.removeProject(withID: secondProjectID)

        XCTAssertTrue(store.document.projects.isEmpty)
        XCTAssertNil(store.document.selectedProjectID)
        XCTAssertNil(store.document.selectedSpaceID)
        XCTAssertNil(store.focusedPaneID)
        XCTAssertEqual(persistence.savedDocuments.count, 2)
    }

    func testRenameTrimsNamesAndKeepsSiblingsDistinct() throws {
        let firstPane = TerminalPane(workingDirectory: "/project")
        let secondPane = TerminalPane(workingDirectory: "/project")
        let firstSpace = TerminalSpace(name: "Server", layout: .terminal(firstPane))
        let secondSpace = TerminalSpace(name: "Tests", layout: .terminal(secondPane))
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(firstSpace), .space(secondSpace)]
        )
        let otherProject = TerminalProject(name: "Other", rootDirectory: "/other")
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project, otherProject],
            selectedProjectID: project.id,
            selectedSpaceID: firstSpace.id
        )
        let store = WorkspaceStore(persistence: persistence)

        store.renameProject(withID: otherProject.id, to: "  Project  ")
        store.renameItem(
            withID: secondSpace.id,
            inProject: project.id,
            to: "  Server  "
        )
        store.renameItem(withID: firstSpace.id, inProject: project.id, to: "   ")

        XCTAssertEqual(store.document.projects[1].name, "Project 2")
        let updatedProject = store.document.projects[0]
        XCTAssertEqual(updatedProject.space(withID: firstSpace.id)?.name, "Server")
        XCTAssertEqual(updatedProject.space(withID: secondSpace.id)?.name, "Server 2")
        XCTAssertEqual(persistence.savedDocuments.count, 2)
    }

    func testPaneNavigationWrapsAndZoomTracksFocus() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let firstPaneID = try XCTUnwrap(store.focusedPaneID)
        store.splitFocusedPane(axis: .horizontal)
        let secondPaneID = try XCTUnwrap(store.focusedPaneID)
        store.splitFocusedPane(axis: .vertical)
        let thirdPaneID = try XCTUnwrap(store.focusedPaneID)

        XCTAssertEqual(
            store.selectedSpace?.layout.orderedTerminalIDs,
            [firstPaneID, secondPaneID, thirdPaneID]
        )

        store.focusNextPane()
        XCTAssertEqual(store.focusedPaneID, firstPaneID)
        store.toggleFocusedPaneZoom()
        XCTAssertEqual(store.zoomedPaneID, firstPaneID)

        store.focusNextPane()
        XCTAssertEqual(store.focusedPaneID, secondPaneID)
        XCTAssertEqual(store.zoomedPaneID, secondPaneID)

        store.focusPreviousPane()
        XCTAssertEqual(store.focusedPaneID, firstPaneID)
        XCTAssertEqual(store.zoomedPaneID, firstPaneID)

        store.toggleFocusedPaneZoom()
        XCTAssertNil(store.zoomedPaneID)
        store.toggleFocusedPaneZoom()
        XCTAssertEqual(store.zoomedPaneID, firstPaneID)

        store.splitFocusedPane(axis: .horizontal)
        XCTAssertNil(store.zoomedPaneID)
        XCTAssertEqual(store.selectedSpace?.layout.terminalCount, 4)
    }

    func testWorkspaceNavigationWrapsThroughNestedSpacesAndProjects() throws {
        let firstPane = TerminalPane(workingDirectory: "/one")
        let secondPane = TerminalPane(workingDirectory: "/one/nested")
        let firstSpace = TerminalSpace(name: "First", layout: .terminal(firstPane))
        let secondSpace = TerminalSpace(name: "Second", layout: .terminal(secondPane))
        let nestedFolder = WorkspaceFolder(
            name: "Nested",
            children: [.space(secondSpace)]
        )
        let firstProject = TerminalProject(
            name: "One",
            rootDirectory: "/one",
            items: [
                .space(firstSpace),
                .folder(nestedFolder),
            ],
            lastSelectedSpaceID: firstSpace.id
        )
        let otherPane = TerminalPane(workingDirectory: "/two")
        let otherSpace = TerminalSpace(name: "Other", layout: .terminal(otherPane))
        let otherProject = TerminalProject(
            name: "Two",
            rootDirectory: "/two",
            items: [.space(otherSpace)],
            lastSelectedSpaceID: otherSpace.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [firstProject, otherProject],
            selectedProjectID: firstProject.id,
            selectedSpaceID: firstSpace.id
        )
        let store = WorkspaceStore(persistence: persistence)

        store.selectPreviousSpace()
        XCTAssertEqual(store.document.selectedSpaceID, secondSpace.id)
        XCTAssertTrue(store.expandedFolderIDs.contains(nestedFolder.id))
        store.selectNextSpace()
        XCTAssertEqual(store.document.selectedSpaceID, firstSpace.id)

        store.selectPreviousProject()
        XCTAssertEqual(store.document.selectedProjectID, otherProject.id)
        XCTAssertEqual(store.focusedPaneID, otherPane.id)
        store.selectNextProject()
        XCTAssertEqual(store.document.selectedProjectID, firstProject.id)
        XCTAssertEqual(store.document.selectedSpaceID, firstSpace.id)
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
