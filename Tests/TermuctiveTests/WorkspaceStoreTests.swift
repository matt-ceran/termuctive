import Combine
import XCTest

@testable import Termuctive

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testVisibleEditorTakesSavePriorityOverNoteBackingThePane() {
        let paneID = UUID()
        let noteID = UUID()

        let target = FocusedDocumentSaveTarget.resolve(
            focusedPaneID: paneID,
            focusedPaneNoteID: noteID,
            selectedNoteID: nil,
            isFocusedPaneEditorPresented: true
        )

        XCTAssertEqual(target, .editor(paneID))
    }

    func testFocusedPaneNoteTakesSavePriorityOverSidebarNote() {
        let paneNoteID = UUID()
        let sidebarNoteID = UUID()

        let target = FocusedDocumentSaveTarget.resolve(
            focusedPaneID: UUID(),
            focusedPaneNoteID: paneNoteID,
            selectedNoteID: sidebarNoteID,
            isFocusedPaneEditorPresented: false
        )

        XCTAssertEqual(target, .note(paneNoteID))
    }

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

    func testTopLevelFolderUsesActiveTerminalDirectory() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let paneID = try XCTUnwrap(store.focusedPaneID)
        store.updateTerminal(
            paneID: paneID,
            workingDirectory: "/tmp/project/service"
        )
        persistence.savedDocuments.removeAll()

        store.addFolder()

        XCTAssertEqual(store.selectedProject?.kind, .folder)
        XCTAssertEqual(store.selectedProject?.rootDirectory, "/tmp/project/service")
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testTopLevelFolderDoesNotBlockAddingProjectAtSameDirectory() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        let url = URL(fileURLWithPath: "/tmp/shared")
        store.addProject(at: url)
        let originalProjectID = try XCTUnwrap(store.selectedProject?.id)
        store.addFolder()
        let folder = try XCTUnwrap(store.selectedProject)
        store.removeProject(withID: originalProjectID)

        store.addProject(at: url)

        XCTAssertEqual(store.document.projects.count, 2)
        XCTAssertEqual(store.document.projects.first, folder)
        XCTAssertEqual(store.document.projects.last?.kind, .project)
        XCTAssertEqual(store.document.projects.last?.rootDirectory, url.path)
        XCTAssertEqual(store.document.selectedProjectID, store.document.projects.last?.id)
    }

    func testGlobalFolderCreationCreatesIndependentTopLevelContainer() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let sourceProject = try XCTUnwrap(store.selectedProject)

        store.addFolder()

        guard store.document.projects.count == 2 else {
            return XCTFail("Expected a new top-level container beside the project.")
        }
        XCTAssertEqual(store.document.projects[0], sourceProject)
        let folder = store.document.projects[1]
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.name, "Folder")
        XCTAssertEqual(folder.rootDirectory, sourceProject.rootDirectory)
        XCTAssertTrue(folder.items.isEmpty)
        XCTAssertEqual(store.document.selectedProjectID, folder.id)
        XCTAssertNil(store.document.selectedSpaceID)
        XCTAssertNil(store.selectedFolderID)
        XCTAssertNil(store.focusedPaneID)

        store.addSpace()

        let updatedFolder = try XCTUnwrap(store.selectedProject)
        guard case .space(let newSpace) = updatedFolder.items.first else {
            return XCTFail("Expected a terminal space inside the new top-level folder.")
        }
        XCTAssertEqual(updatedFolder.items.count, 1)
        XCTAssertEqual(store.document.selectedSpaceID, newSpace.id)
        XCTAssertEqual(
            newSpace.layout.terminal(withID: newSpace.layout.firstTerminalID)?.workingDirectory,
            sourceProject.rootDirectory
        )

        persistence.savedDocuments.removeAll()
        store.removeProject(withID: folder.id)

        XCTAssertEqual(store.document.projects, [sourceProject])
        XCTAssertEqual(store.document.selectedProjectID, sourceProject.id)
        XCTAssertEqual(store.document.selectedSpaceID, sourceProject.firstSpace?.id)
        XCTAssertEqual(store.focusedPaneID, sourceProject.firstSpace?.layout.firstTerminalID)
        XCTAssertFalse(store.document.terminalIDs.contains(newSpace.layout.firstTerminalID))
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testSpaceCanBeAddedInsideSelectedFolder() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)

        store.addFolder(toFolderWithID: nil, inProjectWithID: projectID)
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

    func testNoteCanBeAddedInsideSelectedFolderWithoutRemovingLiveTerminalIdentity() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        let terminalIDs = store.document.terminalIDs
        store.addFolder(toFolderWithID: nil, inProjectWithID: projectID)
        let folderID = try XCTUnwrap(store.selectedFolderID)

        store.addNote()

        let project = try XCTUnwrap(store.selectedProject)
        let note = try XCTUnwrap(project.notes.first)
        XCTAssertEqual(project.ancestorFolderIDs(forItemWithID: note.id), [folderID])
        XCTAssertEqual(store.selectedNote, note)
        XCTAssertEqual(store.document.selectedItemID, note.id)
        XCTAssertNil(store.document.selectedSpaceID)
        XCTAssertNil(store.focusedPaneID)
        XCTAssertEqual(store.document.terminalIDs, terminalIDs)
        XCTAssertTrue(store.expandedFolderIDs.contains(folderID))
    }

    func testNoteTabsStayOpenAcrossTerminalSelectionAndCloseWithoutDeletingNotes() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        let spaceID = try XCTUnwrap(store.selectedSpace?.id)

        store.addNote()
        let firstNoteID = try XCTUnwrap(store.selectedNote?.id)
        store.addNote()
        let secondNoteID = try XCTUnwrap(store.selectedNote?.id)

        XCTAssertEqual(store.document.openNoteIDs, [firstNoteID, secondNoteID])
        XCTAssertEqual(store.openNoteTabs.map(\.id), [firstNoteID, secondNoteID])

        store.selectSpace(withID: spaceID, inProject: projectID)

        XCTAssertEqual(store.document.selectedSpaceID, spaceID)
        XCTAssertEqual(store.document.openNoteIDs, [firstNoteID, secondNoteID])
        XCTAssertEqual(store.openNoteTabs.map(\.id), [firstNoteID, secondNoteID])

        store.closeNoteTab(withID: firstNoteID)

        XCTAssertEqual(store.document.openNoteIDs, [secondNoteID])
        XCTAssertNotNil(store.document.note(withID: firstNoteID))
        XCTAssertEqual(store.document.selectedSpaceID, spaceID)

        store.selectNoteTab(withID: secondNoteID)
        store.closeNoteTab(withID: secondNoteID)

        XCTAssertTrue(store.document.openNoteIDs.isEmpty)
        XCTAssertEqual(store.document.selectedSpaceID, spaceID)
        XCTAssertNotNil(store.document.note(withID: secondNoteID))
        XCTAssertEqual(store.selectedProject?.notes.map(\.id), [firstNoteID, secondNoteID])
        XCTAssertEqual(persistence.savedDocuments.last, store.document)
    }

    func testNoteTabsNormalizeStaleAndDuplicateReferencesOnLoad() {
        let firstNote = ProjectNote(name: "First")
        let secondNote = ProjectNote(name: "Second")
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.note(firstNote), .note(secondNote)],
            lastSelectedItemID: secondNote.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedItemID: secondNote.id,
            openNoteIDs: [UUID(), secondNote.id, secondNote.id, firstNote.id]
        )

        let store = WorkspaceStore(persistence: persistence)

        XCTAssertEqual(store.document.openNoteIDs, [secondNote.id, firstNote.id])
        XCTAssertEqual(store.openNoteTabs.map(\.id), [secondNote.id, firstNote.id])
        XCTAssertEqual(store.document.selectedItemID, secondNote.id)
        XCTAssertTrue(persistence.savedDocuments.isEmpty)
    }

    func testMovingSelectedNoteAcrossProjectsPreservesIdentityPaneAndOpenTab() throws {
        let note = ProjectNote(name: "Plan")
        let sourceTerminalPane = TerminalPane(workingDirectory: "/source")
        let sourceNotePane = TerminalPane(
            workingDirectory: "/source",
            content: .note(note.id)
        )
        let sourceSpace = TerminalSpace(
            name: "Terminal",
            layout: .split(
                PaneSplit(
                    axis: .horizontal,
                    first: .terminal(sourceTerminalPane),
                    second: .terminal(sourceNotePane)
                )
            )
        )
        let sourceFolder = WorkspaceFolder(
            name: "Drafts",
            children: [.note(note)]
        )
        let sourceProject = TerminalProject(
            name: "Source",
            rootDirectory: "/source",
            items: [.space(sourceSpace), .folder(sourceFolder)],
            lastSelectedItemID: note.id,
            lastSelectedSpaceID: sourceSpace.id
        )
        let existingNote = ProjectNote(name: "Plan")
        let destinationFolder = WorkspaceFolder(
            name: "Archive",
            children: [.note(existingNote)]
        )
        let destinationProject = TerminalProject(
            name: "Destination",
            rootDirectory: "/destination",
            items: [.folder(destinationFolder)]
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [sourceProject, destinationProject],
            selectedProjectID: sourceProject.id,
            selectedItemID: note.id,
            openTerminalSpaceIDs: [sourceSpace.id],
            openNoteIDs: [note.id]
        )
        let store = WorkspaceStore(persistence: persistence)
        let terminalIDs = store.document.terminalIDs

        let moved = store.moveNote(
            withID: note.id,
            fromProjectWithID: sourceProject.id,
            toProjectWithID: destinationProject.id,
            toFolderWithID: destinationFolder.id
        )

        XCTAssertTrue(moved)
        XCTAssertNil(store.document.projects[0].note(withID: note.id))
        let movedNote = try XCTUnwrap(store.document.projects[1].note(withID: note.id))
        XCTAssertEqual(movedNote.name, "Plan 2")
        XCTAssertEqual(
            store.document.projects[1].ancestorFolderIDs(forItemWithID: note.id),
            [destinationFolder.id]
        )
        XCTAssertEqual(store.document.selectedProjectID, destinationProject.id)
        XCTAssertEqual(store.selectedNote?.id, note.id)
        XCTAssertEqual(store.document.openNoteIDs, [note.id])
        XCTAssertEqual(store.openNoteTabs.first?.projectID, destinationProject.id)
        XCTAssertEqual(store.openNoteTabs.first?.noteName, "Plan 2")
        XCTAssertEqual(store.document.terminalIDs, terminalIDs)
        XCTAssertEqual(
            store.document.projects[0].space(withID: sourceSpace.id)?
                .layout.terminal(withID: sourceNotePane.id)?.content,
            .note(note.id)
        )
        XCTAssertEqual(
            store.document.projects[0].lastSelectedItemID,
            sourceSpace.id
        )
        XCTAssertTrue(store.expandedProjectIDs.contains(destinationProject.id))
        XCTAssertTrue(store.expandedFolderIDs.contains(destinationFolder.id))
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testMovingNoteRejectsItsCurrentContainerAndInvalidDestinations() {
        let note = ProjectNote(name: "Plan")
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.note(note)],
            lastSelectedItemID: note.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedItemID: note.id
        )
        let store = WorkspaceStore(persistence: persistence)

        XCTAssertFalse(
            store.moveNote(
                withID: note.id,
                fromProjectWithID: project.id,
                toProjectWithID: project.id,
                toFolderWithID: nil
            )
        )
        XCTAssertFalse(
            store.moveNote(
                withID: note.id,
                fromProjectWithID: project.id,
                toProjectWithID: project.id,
                toFolderWithID: UUID()
            )
        )
        XCTAssertFalse(
            store.moveNote(
                withID: note.id,
                fromProjectWithID: UUID(),
                toProjectWithID: project.id,
                toFolderWithID: nil
            )
        )

        XCTAssertEqual(store.document.projects, [project])
        XCTAssertTrue(persistence.savedDocuments.isEmpty)
    }

    func testAddingNotePaneCreatesSidebarNoteAndKeepsTerminalSpaceSelected() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let originalPaneID = try XCTUnwrap(store.focusedPaneID)
        let spaceID = try XCTUnwrap(store.selectedSpace?.id)
        persistence.savedDocuments.removeAll()

        let notePaneID = try XCTUnwrap(store.addNotePane(axis: .horizontal))

        let project = try XCTUnwrap(store.selectedProject)
        let note = try XCTUnwrap(project.notes.first)
        let notePane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: notePaneID)
        )
        XCTAssertEqual(project.notes.count, 1)
        XCTAssertEqual(notePane.content, .note(note.id))
        XCTAssertEqual(
            store.selectedSpace?.layout.orderedTerminalIDs,
            [originalPaneID, notePaneID]
        )
        XCTAssertEqual(store.document.selectedItemID, spaceID)
        XCTAssertEqual(store.document.selectedSpaceID, spaceID)
        XCTAssertNil(store.selectedNote)
        XCTAssertEqual(store.focusedPaneID, notePaneID)
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testExistingSidebarNoteCanOpenInPaneWithoutDuplication() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        store.addNote()
        let noteID = try XCTUnwrap(store.selectedNote?.id)
        persistence.savedDocuments.removeAll()

        let paneID = try XCTUnwrap(
            store.openNoteInNewPane(
                noteID: noteID,
                inProjectWithID: projectID,
                axis: .vertical
            )
        )

        XCTAssertEqual(store.selectedProject?.notes.map(\.id), [noteID])
        XCTAssertEqual(
            store.selectedSpace?.layout.terminal(withID: paneID)?.content,
            .note(noteID)
        )
        XCTAssertEqual(store.selectedSpace?.layout.terminalCount, 2)
        XCTAssertEqual(store.focusedPaneID, paneID)
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testOpeningAnAlreadyVisibleNoteFocusesItsExistingPane() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        let firstPaneID = try XCTUnwrap(store.addNotePane(axis: .horizontal))
        let noteID = try XCTUnwrap(store.focusedPaneNote?.id)
        store.focusPreviousPane()
        persistence.savedDocuments.removeAll()

        let reopenedPaneID = try XCTUnwrap(
            store.openNoteInNewPane(
                noteID: noteID,
                inProjectWithID: projectID,
                axis: .vertical
            )
        )

        XCTAssertEqual(reopenedPaneID, firstPaneID)
        XCTAssertEqual(store.focusedPaneID, firstPaneID)
        XCTAssertEqual(store.selectedSpace?.layout.terminalCount, 2)
        XCTAssertEqual(store.selectedProject?.notes.map(\.id), [noteID])
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testPaneCapabilityUsesTheTargetProjectInsteadOfSelection() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/with-space"))
        let projectWithSpaceID = try XCTUnwrap(store.selectedProject?.id)
        store.addFolder()
        let emptyFolderID = try XCTUnwrap(store.selectedProject?.id)

        XCTAssertFalse(store.canAddPane)
        XCTAssertTrue(store.canAddPane(inProjectWithID: projectWithSpaceID))
        XCTAssertFalse(store.canAddPane(inProjectWithID: emptyFolderID))
    }

    func testRemovingSidebarNoteReturnsItsPaneToTerminalContent() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        let notePaneID = try XCTUnwrap(store.addNotePane(axis: .horizontal))
        let noteID = try XCTUnwrap(store.focusedPaneNote?.id)
        persistence.savedDocuments.removeAll()

        let removedNoteIDs = store.removeItem(withID: noteID, inProject: projectID)

        XCTAssertEqual(removedNoteIDs, [noteID])
        XCTAssertTrue(store.selectedProject?.notes.isEmpty == true)
        XCTAssertEqual(
            store.selectedSpace?.layout.terminal(withID: notePaneID)?.content,
            .terminal
        )
        XCTAssertEqual(store.focusedPaneID, notePaneID)
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testSwitchingProjectsRestoresNoteAndTerminalSelectionsIndependently() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/notes"))
        let notesProjectID = try XCTUnwrap(store.selectedProject?.id)
        let retainedTerminalIDs = store.document.terminalIDs
        store.addNote()
        let noteID = try XCTUnwrap(store.selectedNote?.id)
        store.addProject(at: URL(fileURLWithPath: "/tmp/terminal"))
        let terminalProjectID = try XCTUnwrap(store.selectedProject?.id)
        let terminalSpaceID = try XCTUnwrap(store.selectedSpace?.id)

        store.selectProject(withID: notesProjectID)
        XCTAssertEqual(store.selectedNote?.id, noteID)
        XCTAssertNil(store.focusedPaneID)
        XCTAssertTrue(store.document.terminalIDs.isSuperset(of: retainedTerminalIDs))

        store.selectProject(withID: terminalProjectID)
        XCTAssertEqual(store.selectedSpace?.id, terminalSpaceID)
        XCTAssertNotNil(store.focusedPaneID)
    }

    func testRemovingSelectedNoteReturnsItsIdentifierAndRestoresTerminalSpace() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        let spaceID = try XCTUnwrap(store.selectedSpace?.id)
        let paneID = try XCTUnwrap(store.focusedPaneID)
        store.addNote()
        let noteID = try XCTUnwrap(store.selectedNote?.id)

        let removedNoteIDs = store.removeItem(withID: noteID, inProject: projectID)

        XCTAssertEqual(removedNoteIDs, [noteID])
        XCTAssertEqual(store.selectedSpace?.id, spaceID)
        XCTAssertEqual(store.focusedPaneID, paneID)
        XCTAssertNil(store.selectedNote)
        XCTAssertEqual(persistence.savedDocuments.last, store.document)
    }

    func testSpaceCanBeAddedToExplicitFolderInAnotherProject() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/first"))
        let firstProjectID = try XCTUnwrap(store.selectedProject?.id)
        store.addFolder(toFolderWithID: nil, inProjectWithID: firstProjectID)
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

    func testFolderCanBeAddedToExplicitParentWithoutChangingRootStructure() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        store.addFolder(toFolderWithID: nil, inProjectWithID: projectID)
        let parentFolderID = try XCTUnwrap(store.selectedFolderID)

        store.addFolder(
            toFolderWithID: parentFolderID,
            inProjectWithID: projectID
        )

        let project = try XCTUnwrap(store.selectedProject)
        XCTAssertEqual(project.items.count, 2)
        guard case .folder(let parentFolder) = project.items.last,
            case .folder(let childFolder) = parentFolder.children.first
        else {
            return XCTFail("Expected a nested folder inside the explicit parent.")
        }
        XCTAssertEqual(parentFolder.id, parentFolderID)
        XCTAssertEqual(parentFolder.children.count, 1)
        XCTAssertEqual(store.selectedFolderID, childFolder.id)
        XCTAssertTrue(store.expandedFolderIDs.isSuperset(of: [parentFolder.id, childFolder.id]))
    }

    func testInvalidCreationAndRemovalTargetsDoNotMutateOrPersist() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        let originalDocument = store.document
        let originalFocusedPaneID = store.focusedPaneID
        let originalExpandedProjectIDs = store.expandedProjectIDs
        persistence.savedDocuments.removeAll()

        store.addFolder(
            toFolderWithID: UUID(),
            inProjectWithID: projectID
        )
        store.addSpace(
            toFolderWithID: UUID(),
            inProjectWithID: projectID
        )
        store.addFolder(
            toFolderWithID: nil,
            inProjectWithID: UUID()
        )
        store.addSpace(
            toFolderWithID: nil,
            inProjectWithID: UUID()
        )
        store.removeItem(withID: UUID(), inProject: projectID)
        store.removeItem(withID: UUID(), inProject: UUID())
        store.removeProject(withID: UUID())

        XCTAssertEqual(store.document, originalDocument)
        XCTAssertEqual(store.focusedPaneID, originalFocusedPaneID)
        XCTAssertEqual(store.expandedProjectIDs, originalExpandedProjectIDs)
        XCTAssertTrue(persistence.savedDocuments.isEmpty)
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

    func testPreparingPDFDoesNotReplaceAnExistingNotePane() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let commandPaneID = try XCTUnwrap(store.focusedPaneID)
        let notePaneID = try XCTUnwrap(store.addNotePane(axis: .horizontal))
        let noteID = try XCTUnwrap(store.focusedPaneNote?.id)
        store.focusPane(withID: commandPaneID)

        let pdfPaneID = try XCTUnwrap(
            store.preparePDFPane(
                fromPaneID: commandPaneID,
                placement: .right
            )
        )

        XCTAssertNotEqual(pdfPaneID, notePaneID)
        XCTAssertEqual(store.selectedSpace?.layout.terminalCount, 3)
        XCTAssertEqual(
            store.selectedSpace?.layout.terminal(withID: notePaneID)?.content,
            .note(noteID)
        )
        XCTAssertEqual(
            store.selectedSpace?.layout.terminal(withID: pdfPaneID)?.content,
            .terminal
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
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        store.addFolder(toFolderWithID: nil, inProjectWithID: projectID)
        let folderID = try XCTUnwrap(store.selectedFolderID)

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

    func testRemovingPopulatedUnselectedFolderPreservesActiveTerminal() throws {
        let activePane = TerminalPane(workingDirectory: "/project")
        let activeSpace = TerminalSpace(
            name: "Active",
            layout: .terminal(activePane)
        )
        let firstRemovedPane = TerminalPane(workingDirectory: "/project/service")
        let firstRemovedSpace = TerminalSpace(
            name: "Service",
            layout: .terminal(firstRemovedPane)
        )
        let secondRemovedPane = TerminalPane(workingDirectory: "/project/tests")
        let secondRemovedSpace = TerminalSpace(
            name: "Tests",
            layout: .terminal(secondRemovedPane)
        )
        let nestedFolder = WorkspaceFolder(
            name: "Nested",
            children: [.space(secondRemovedSpace)]
        )
        let removedFolder = WorkspaceFolder(
            name: "Services",
            children: [.space(firstRemovedSpace), .folder(nestedFolder)]
        )
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(activeSpace), .folder(removedFolder)],
            lastSelectedSpaceID: activeSpace.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: activeSpace.id
        )
        let store = WorkspaceStore(persistence: persistence)
        store.toggleFolder(withID: removedFolder.id)
        store.toggleFolder(withID: nestedFolder.id)

        store.removeItem(withID: removedFolder.id, inProject: project.id)

        XCTAssertEqual(store.document.selectedSpaceID, activeSpace.id)
        XCTAssertEqual(store.focusedPaneID, activePane.id)
        XCTAssertEqual(store.selectedProject?.items, [.space(activeSpace)])
        XCTAssertFalse(store.document.terminalIDs.contains(firstRemovedPane.id))
        XCTAssertFalse(store.document.terminalIDs.contains(secondRemovedPane.id))
        XCTAssertFalse(store.expandedFolderIDs.contains(removedFolder.id))
        XCTAssertFalse(store.expandedFolderIDs.contains(nestedFolder.id))
        XCTAssertEqual(persistence.savedDocuments, [store.document])
    }

    func testRemovalScopeFindsEveryTerminalInANestedFolder() {
        let activePane = TerminalPane(workingDirectory: "/project")
        let activeSpace = TerminalSpace(
            name: "Active",
            layout: .terminal(activePane)
        )
        let firstNestedPane = TerminalPane(workingDirectory: "/project/service")
        let firstNestedSpace = TerminalSpace(
            name: "Service",
            layout: .terminal(firstNestedPane)
        )
        let secondNestedPane = TerminalPane(workingDirectory: "/project/tests")
        let secondNestedSpace = TerminalSpace(
            name: "Tests",
            layout: .terminal(secondNestedPane)
        )
        let nestedFolder = WorkspaceFolder(
            name: "Nested",
            children: [.space(secondNestedSpace)]
        )
        let rootFolder = WorkspaceFolder(
            name: "Services",
            children: [.space(firstNestedSpace), .folder(nestedFolder)]
        )
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(activeSpace), .folder(rootFolder)]
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: activeSpace.id
        )
        let store = WorkspaceStore(persistence: persistence)

        XCTAssertEqual(
            store.terminalIDs(
                inItemWithID: rootFolder.id,
                inProjectWithID: project.id
            ),
            [firstNestedPane.id, secondNestedPane.id]
        )
        XCTAssertEqual(
            store.terminalIDs(
                inItemWithID: nestedFolder.id,
                inProjectWithID: project.id
            ),
            [secondNestedPane.id]
        )
        XCTAssertEqual(
            store.terminalIDs(inProjectWithID: project.id),
            [activePane.id, firstNestedPane.id, secondNestedPane.id]
        )
    }

    func testRemovingOnlyTerminalSpaceAllowsCreatingReplacement() throws {
        let persistence = RecordingPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        let projectID = try XCTUnwrap(store.selectedProject?.id)
        let removedSpaceID = try XCTUnwrap(store.selectedSpace?.id)
        persistence.savedDocuments.removeAll()

        store.removeItem(withID: removedSpaceID, inProject: projectID)

        XCTAssertTrue(try XCTUnwrap(store.selectedProject).items.isEmpty)
        XCTAssertNil(store.document.selectedSpaceID)
        XCTAssertNil(store.focusedPaneID)

        store.addSpace()

        let replacementSpace = try XCTUnwrap(store.selectedSpace)
        let replacementPaneID = try XCTUnwrap(replacementSpace.layout.firstTerminalID)
        XCTAssertEqual(try XCTUnwrap(store.selectedProject).items, [.space(replacementSpace)])
        XCTAssertEqual(store.focusedPaneID, replacementPaneID)
        XCTAssertEqual(
            replacementSpace.layout.terminal(withID: replacementPaneID)?.workingDirectory,
            "/tmp/project"
        )
        XCTAssertEqual(persistence.savedDocuments.count, 2)
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

    func testTerminalTabsNormalizeStaleAndDuplicateReferencesOnLoad() {
        let firstPane = TerminalPane(workingDirectory: "/project/first")
        let secondPane = TerminalPane(workingDirectory: "/project/second")
        let firstSpace = TerminalSpace(name: "First", layout: .terminal(firstPane))
        let secondSpace = TerminalSpace(name: "Second", layout: .terminal(secondPane))
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(firstSpace), .space(secondSpace)],
            lastSelectedSpaceID: secondSpace.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: secondSpace.id,
            openTerminalSpaceIDs: [UUID(), secondSpace.id, secondSpace.id, firstSpace.id]
        )

        let store = WorkspaceStore(persistence: persistence)

        XCTAssertEqual(store.document.openTerminalSpaceIDs, [secondSpace.id, firstSpace.id])
        XCTAssertEqual(store.openTerminalSpaceTabs.map(\.id), [secondSpace.id, firstSpace.id])
        XCTAssertEqual(store.document.selectedSpaceID, secondSpace.id)
        XCTAssertEqual(store.focusedPaneID, secondPane.id)
        XCTAssertTrue(persistence.savedDocuments.isEmpty)
    }

    func testTerminalTabDropPlacementUsesTheLeadingAndTrailingTargetHalves() {
        let leadingID = UUID()
        let trailingID = UUID()

        XCTAssertEqual(
            TerminalSpaceTabDropPlacement.anchorID(
                leading: leadingID,
                trailing: trailingID,
                locationX: 20,
                targetWidth: 100
            ),
            leadingID
        )
        XCTAssertEqual(
            TerminalSpaceTabDropPlacement.anchorID(
                leading: leadingID,
                trailing: trailingID,
                locationX: 80,
                targetWidth: 100
            ),
            trailingID
        )
        XCTAssertNil(
            TerminalSpaceTabDropPlacement.anchorID(
                leading: leadingID,
                trailing: nil,
                locationX: 80,
                targetWidth: 100
            )
        )
    }

    func testOpeningSelectingAndReorderingTerminalTabsSavesOnlyRealChanges() {
        let firstSpace = TerminalSpace(
            name: "First",
            layout: .terminal(TerminalPane(workingDirectory: "/project/first"))
        )
        let secondSpace = TerminalSpace(
            name: "Second",
            layout: .terminal(TerminalPane(workingDirectory: "/project/second"))
        )
        let thirdSpace = TerminalSpace(
            name: "Third",
            layout: .terminal(TerminalPane(workingDirectory: "/project/third"))
        )
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(firstSpace), .space(secondSpace), .space(thirdSpace)],
            lastSelectedSpaceID: firstSpace.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: firstSpace.id,
            openTerminalSpaceIDs: [firstSpace.id]
        )
        let store = WorkspaceStore(persistence: persistence)

        store.selectTerminalSpaceTab(withID: secondSpace.id)

        XCTAssertEqual(store.document.openTerminalSpaceIDs, [firstSpace.id, secondSpace.id])
        XCTAssertEqual(store.document.selectedSpaceID, secondSpace.id)
        XCTAssertEqual(persistence.savedDocuments.count, 1)

        store.selectSpace(withID: secondSpace.id, inProject: project.id)
        store.placeTerminalSpaceTab(withID: thirdSpace.id, before: secondSpace.id)

        XCTAssertEqual(
            store.document.openTerminalSpaceIDs,
            [firstSpace.id, thirdSpace.id, secondSpace.id]
        )
        XCTAssertEqual(store.document.selectedSpaceID, thirdSpace.id)
        XCTAssertEqual(persistence.savedDocuments.count, 2)

        store.reorderTerminalSpaceTab(withID: firstSpace.id, before: firstSpace.id)
        store.reorderTerminalSpaceTab(withID: UUID(), before: firstSpace.id)
        store.reorderTerminalSpaceTab(withID: secondSpace.id, before: UUID())

        XCTAssertEqual(
            store.document.openTerminalSpaceIDs,
            [firstSpace.id, thirdSpace.id, secondSpace.id]
        )
        XCTAssertEqual(store.document.selectedSpaceID, thirdSpace.id)
        XCTAssertEqual(persistence.savedDocuments.count, 2)

        store.reorderTerminalSpaceTab(withID: secondSpace.id, before: firstSpace.id)

        XCTAssertEqual(
            store.document.openTerminalSpaceIDs,
            [secondSpace.id, firstSpace.id, thirdSpace.id]
        )
        XCTAssertEqual(store.document.selectedSpaceID, thirdSpace.id)
        XCTAssertEqual(persistence.savedDocuments.count, 3)
        XCTAssertEqual(persistence.savedDocuments.last, store.document)
    }

    func testClosingInactiveActiveAndLastTerminalTabsIsNondestructive() {
        let firstPane = TerminalPane(workingDirectory: "/project/first")
        let secondPane = TerminalPane(workingDirectory: "/project/second")
        let thirdPane = TerminalPane(workingDirectory: "/project/third")
        let firstSpace = TerminalSpace(name: "First", layout: .terminal(firstPane))
        let secondSpace = TerminalSpace(name: "Second", layout: .terminal(secondPane))
        let thirdSpace = TerminalSpace(name: "Third", layout: .terminal(thirdPane))
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(firstSpace), .space(secondSpace), .space(thirdSpace)],
            lastSelectedSpaceID: firstSpace.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: firstSpace.id,
            openTerminalSpaceIDs: [firstSpace.id, secondSpace.id, thirdSpace.id]
        )
        let store = WorkspaceStore(persistence: persistence)
        let originalTerminalIDs = store.document.terminalIDs

        store.closeTerminalSpaceTab(withID: thirdSpace.id)

        XCTAssertEqual(store.document.openTerminalSpaceIDs, [firstSpace.id, secondSpace.id])
        XCTAssertEqual(store.document.selectedSpaceID, firstSpace.id)
        XCTAssertEqual(store.document.terminalIDs, originalTerminalIDs)
        XCTAssertEqual(persistence.savedDocuments.count, 1)

        store.closeTerminalSpaceTab(withID: thirdSpace.id)

        XCTAssertEqual(persistence.savedDocuments.count, 1)

        store.closeTerminalSpaceTab(withID: firstSpace.id)

        XCTAssertEqual(store.document.openTerminalSpaceIDs, [secondSpace.id])
        XCTAssertEqual(store.document.selectedSpaceID, secondSpace.id)
        XCTAssertEqual(store.focusedPaneID, secondPane.id)
        XCTAssertEqual(store.document.terminalIDs, originalTerminalIDs)
        XCTAssertEqual(persistence.savedDocuments.count, 2)

        store.closeTerminalSpaceTab(withID: secondSpace.id)

        XCTAssertTrue(store.document.openTerminalSpaceIDs.isEmpty)
        XCTAssertNil(store.document.selectedSpaceID)
        XCTAssertNil(store.document.selectedItemID)
        XCTAssertEqual(store.document.selectedProjectID, project.id)
        XCTAssertEqual(store.document.terminalIDs, originalTerminalIDs)
        XCTAssertNotNil(store.document.space(withID: firstSpace.id))
        XCTAssertNotNil(store.document.space(withID: secondSpace.id))
        XCTAssertNotNil(store.document.space(withID: thirdSpace.id))
        XCTAssertEqual(persistence.savedDocuments.count, 3)
    }

    func testTerminalTabsRestorePerSpaceFocusAndZoomAcrossCrossProjectAdd() throws {
        let firstPane = TerminalPane(workingDirectory: "/one")
        let secondPane = TerminalPane(workingDirectory: "/one/tests")
        let firstSpace = TerminalSpace(
            name: "First",
            layout: .split(
                PaneSplit(
                    axis: .horizontal,
                    first: .terminal(firstPane),
                    second: .terminal(secondPane)
                )
            )
        )
        let firstProject = TerminalProject(
            name: "One",
            rootDirectory: "/one",
            items: [.space(firstSpace)],
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
            selectedSpaceID: firstSpace.id,
            openTerminalSpaceIDs: [firstSpace.id, otherSpace.id]
        )
        let store = WorkspaceStore(persistence: persistence)

        store.focusPane(withID: secondPane.id)
        store.toggleFocusedPaneZoom()
        store.selectTerminalSpaceTab(withID: otherSpace.id)

        XCTAssertEqual(store.focusedPaneID, otherPane.id)
        XCTAssertNil(store.zoomedPaneID)

        store.selectTerminalSpaceTab(withID: firstSpace.id)

        XCTAssertEqual(store.focusedPaneID, secondPane.id)
        XCTAssertEqual(store.zoomedPaneID, secondPane.id)

        store.addSpace(toFolderWithID: nil, inProjectWithID: otherProject.id)
        let addedSpaceID = try XCTUnwrap(store.document.selectedSpaceID)
        let addedPaneID = try XCTUnwrap(store.focusedPaneID)

        XCTAssertNotEqual(addedSpaceID, firstSpace.id)
        XCTAssertNotEqual(addedSpaceID, otherSpace.id)
        XCTAssertTrue(store.document.openTerminalSpaceIDs.contains(addedSpaceID))
        XCTAssertTrue(
            try XCTUnwrap(store.document.space(withID: addedSpaceID))
                .layout.terminalIDs.contains(addedPaneID)
        )
        XCTAssertNil(store.zoomedPaneID)

        store.selectTerminalSpaceTab(withID: firstSpace.id)

        XCTAssertEqual(store.focusedPaneID, secondPane.id)
        XCTAssertEqual(store.zoomedPaneID, secondPane.id)
    }

    func testDeletingSelectedTerminalTabChoosesRightThenLeftSurvivor() {
        let firstPane = TerminalPane(workingDirectory: "/one")
        let firstSpace = TerminalSpace(name: "First", layout: .terminal(firstPane))
        let firstProject = TerminalProject(
            name: "One",
            rootDirectory: "/one",
            items: [.space(firstSpace)],
            lastSelectedSpaceID: firstSpace.id
        )
        let middlePane = TerminalPane(workingDirectory: "/two/middle")
        let lastPane = TerminalPane(workingDirectory: "/two/last")
        let middleSpace = TerminalSpace(name: "Middle", layout: .terminal(middlePane))
        let lastSpace = TerminalSpace(name: "Last", layout: .terminal(lastPane))
        let secondProject = TerminalProject(
            name: "Two",
            rootDirectory: "/two",
            items: [.space(middleSpace), .space(lastSpace)],
            lastSelectedSpaceID: middleSpace.id
        )
        let persistence = RecordingPersistence()
        persistence.loadedDocument = WorkspaceDocument(
            projects: [firstProject, secondProject],
            selectedProjectID: secondProject.id,
            selectedSpaceID: middleSpace.id,
            openTerminalSpaceIDs: [firstSpace.id, middleSpace.id, lastSpace.id]
        )
        let store = WorkspaceStore(persistence: persistence)

        store.removeItem(withID: middleSpace.id, inProject: secondProject.id)

        XCTAssertEqual(store.document.openTerminalSpaceIDs, [firstSpace.id, lastSpace.id])
        XCTAssertEqual(store.document.selectedSpaceID, lastSpace.id)
        XCTAssertEqual(store.focusedPaneID, lastPane.id)
        XCTAssertFalse(store.document.terminalIDs.contains(middlePane.id))
        XCTAssertEqual(persistence.savedDocuments.count, 1)

        store.removeProject(withID: secondProject.id)

        XCTAssertEqual(store.document.openTerminalSpaceIDs, [firstSpace.id])
        XCTAssertEqual(store.document.selectedProjectID, firstProject.id)
        XCTAssertEqual(store.document.selectedSpaceID, firstSpace.id)
        XCTAssertEqual(store.focusedPaneID, firstPane.id)
        XCTAssertFalse(store.document.terminalIDs.contains(lastPane.id))
        XCTAssertEqual(persistence.savedDocuments.count, 2)
    }

    func testBackgroundPersistenceDoesNotBlockAndCoalescesLatestRatio() async throws {
        let firstPane = TerminalPane(workingDirectory: "/project")
        let secondPane = TerminalPane(workingDirectory: "/project")
        let split = PaneSplit(
            axis: .horizontal,
            first: .terminal(firstPane),
            second: .terminal(secondPane)
        )
        let space = TerminalSpace(name: "Terminal", layout: .split(split))
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(space)],
            lastSelectedSpaceID: space.id
        )
        let persistence = SlowBackgroundWorkspacePersistence(
            loadedDocument: WorkspaceDocument(
                projects: [project],
                selectedProjectID: project.id,
                selectedSpaceID: space.id
            )
        )
        let store = WorkspaceStore(persistence: persistence)

        store.commitSplitRatio(splitID: split.id, ratio: 0.6)
        store.commitSplitRatio(splitID: split.id, ratio: 0.72)

        let mainActorResponded = expectation(description: "Main actor stayed responsive")
        Task { @MainActor in
            mainActorResponded.fulfill()
        }
        await fulfillment(of: [mainActorResponded], timeout: 0.1)

        try await store.flushPersistence()

        let savedDocuments = persistence.savedDocuments
        XCTAssertEqual(savedDocuments.count, 1)
        guard case .split(let savedSplit) = savedDocuments.last?.selectedSpace?.layout else {
            return XCTFail("Expected the latest split snapshot.")
        }
        XCTAssertEqual(savedSplit.ratio, 0.72)
    }

    func testFlushRetriesAFailedBackgroundWorkspaceSave() async throws {
        let persistence = FailOnceBackgroundWorkspacePersistence()
        let store = WorkspaceStore(persistence: persistence)

        store.addProject(at: URL(fileURLWithPath: "/tmp/project"))
        try await store.flushPersistence()

        XCTAssertEqual(persistence.attemptCount, 2)
        XCTAssertEqual(persistence.savedDocument, store.document)
        XCTAssertFalse(store.hasPendingPersistence)
    }

    func testMutationDuringFailedSaveRetryRemainsSerializedAndPersistsLatestDocument()
        async throws
    {
        let retryStarted = expectation(description: "Failed save retry started")
        let persistence = ControlledRetryWorkspacePersistence {
            retryStarted.fulfill()
        }
        let store = WorkspaceStore(persistence: persistence)

        store.addProject(at: URL(fileURLWithPath: "/tmp/first-project"))
        let flushTask = Task { @MainActor in
            try await store.flushPersistence()
        }
        await fulfillment(of: [retryStarted], timeout: 2)

        store.addProject(at: URL(fileURLWithPath: "/tmp/latest-project"))
        persistence.releaseRetry()
        try await flushTask.value

        XCTAssertEqual(persistence.maximumConcurrentSaveCount, 1)
        XCTAssertEqual(persistence.savedDocuments.last, store.document)
        XCTAssertEqual(persistence.savedDocuments.last?.projects.count, 2)
        XCTAssertFalse(store.hasPendingPersistence)
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

private final class SlowBackgroundWorkspacePersistence: WorkspacePersisting {
    let prefersBackgroundSaves = true

    private let lock = NSLock()
    private let loadedDocument: WorkspaceDocument
    private var storedDocuments: [WorkspaceDocument] = []

    init(loadedDocument: WorkspaceDocument) {
        self.loadedDocument = loadedDocument
    }

    var savedDocuments: [WorkspaceDocument] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedDocuments
    }

    func load() throws -> WorkspaceDocument? {
        loadedDocument
    }

    func save(_ document: WorkspaceDocument) throws {
        Thread.sleep(forTimeInterval: 0.25)
        lock.lock()
        storedDocuments.append(document)
        lock.unlock()
    }
}

private final class FailOnceBackgroundWorkspacePersistence: WorkspacePersisting {
    let prefersBackgroundSaves = true

    private let lock = NSLock()
    private var attempts = 0
    private var storedDocument: WorkspaceDocument?

    var attemptCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return attempts
    }

    var savedDocument: WorkspaceDocument? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedDocument
    }

    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {
        lock.lock()
        attempts += 1
        let shouldFail = attempts == 1
        if !shouldFail {
            storedDocument = document
        }
        lock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class ControlledRetryWorkspacePersistence: WorkspacePersisting {
    let prefersBackgroundSaves = true

    private let lock = NSLock()
    private let retryStarted: () -> Void
    private let retryRelease = DispatchSemaphore(value: 0)
    private var attemptCount = 0
    private var activeSaveCount = 0
    private var maximumActiveSaveCount = 0
    private var storedDocuments: [WorkspaceDocument] = []

    init(retryStarted: @escaping () -> Void) {
        self.retryStarted = retryStarted
    }

    var maximumConcurrentSaveCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return maximumActiveSaveCount
    }

    var savedDocuments: [WorkspaceDocument] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedDocuments
    }

    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {
        lock.lock()
        attemptCount += 1
        let attempt = attemptCount
        activeSaveCount += 1
        maximumActiveSaveCount = max(maximumActiveSaveCount, activeSaveCount)
        lock.unlock()
        defer {
            lock.lock()
            activeSaveCount -= 1
            lock.unlock()
        }

        if attempt == 1 {
            throw CocoaError(.fileWriteUnknown)
        }
        if attempt == 2 {
            retryStarted()
            _ = retryRelease.wait(timeout: .now() + 5)
        }

        lock.lock()
        storedDocuments.append(document)
        lock.unlock()
    }

    func releaseRetry() {
        retryRelease.signal()
    }
}
