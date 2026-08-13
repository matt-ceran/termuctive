import AppKit
import SwiftUI
import XCTest

@testable import Termuctive

@MainActor
final class ProjectNotesIntegrationTests: XCTestCase {
    func testSwitchingBetweenTerminalAndNotePreservesTheTerminalAndRendersEveryNoteMode()
        async throws
    {
        let fileManager = FileManager.default
        let projectDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "termuctive-project-notes-integration-\(UUID().uuidString)",
            isDirectory: true
        )
        let notesDirectory = projectDirectory.appendingPathComponent(
            "Saved Notes", isDirectory: true)
        try fileManager.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: projectDirectory)
        }

        let defaultsSuiteName = "TermuctiveTests.ProjectNotesIntegration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let originalAppearance = NSApplication.shared.appearance
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            NSApplication.shared.appearance = originalAppearance
        }

        let store = WorkspaceStore(persistence: ProjectNotesWorkspacePersistence())
        store.addProject(at: projectDirectory)
        let projectID = try XCTUnwrap(store.document.selectedProjectID)
        let spaceID = try XCTUnwrap(store.document.selectedSpaceID)
        let pane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: try XCTUnwrap(store.focusedPaneID))
        )
        let sessions = TerminalSessionPool(store: store)
        let editors = EditorSessionPool(store: store)
        let noteStore = NoteFileStore(directoryURL: notesDirectory)
        let notes = NoteSessionPool(persistence: noteStore)
        let appearance = AppearanceSettings(defaults: defaults)
        let terminalView = sessions.terminalView(for: pane)
        defer {
            notes.terminateAll()
            editors.terminateAll()
            sessions.terminateAll()
        }

        let rootView = WorkspaceView(
            store: store,
            sessions: sessions,
            editors: editors,
            notes: notes,
            appearance: appearance
        )
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 740),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        try await waitUntil("the original terminal to render") {
            terminalView.isDescendant(of: hostingView)
        }
        let terminalIDsBeforeNote = store.document.terminalIDs

        store.addNote()
        let note = try XCTUnwrap(store.selectedNote)
        let noteSession = notes.session(for: note)
        try await waitUntil("the text note editor to replace the terminal") {
            self.firstSubview(of: NSTextView.self, in: hostingView) != nil
                && !terminalView.isDescendant(of: hostingView)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let textView = try XCTUnwrap(firstSubview(of: NSTextView.self, in: hostingView))
        textView.insertText("Concept notes", replacementRange: NSRange(location: 0, length: 0))
        try await waitUntil("the rich-text edit to reach the note document") {
            NoteRichTextArchive.attributedString(from: noteSession.document.richTextRTF).string
                == "Concept notes"
        }

        XCTAssertEqual(store.document.terminalIDs, terminalIDsBeforeNote)
        XCTAssertTrue(sessions.terminalView(for: pane) === terminalView)

        store.addNote()
        let secondNote = try XCTUnwrap(store.selectedNote)
        let secondNoteSession = notes.session(for: secondNote)
        try await waitUntil("a fresh editor for the second note") {
            self.firstSubview(of: NSTextView.self, in: hostingView)?.string.isEmpty == true
        }
        let secondTextView = try XCTUnwrap(firstSubview(of: NSTextView.self, in: hostingView))
        secondTextView.insertText(
            "Separate note",
            replacementRange: NSRange(location: 0, length: 0)
        )
        try await waitUntil("the second note text to remain separate") {
            NoteRichTextArchive.attributedString(
                from: secondNoteSession.document.richTextRTF
            ).string == "Separate note"
        }
        store.selectNote(withID: note.id, inProject: projectID)
        try await waitUntil("the first note text to return") {
            self.firstSubview(of: NSTextView.self, in: hostingView)?.string == "Concept notes"
        }
        XCTAssertEqual(
            NoteRichTextArchive.attributedString(
                from: secondNoteSession.document.richTextRTF
            ).string,
            "Separate note"
        )

        noteSession.updateWorkspaceMode(.split)
        try await waitUntil("the split text and drawing editors to render") {
            self.firstSubview(of: NSTextView.self, in: hostingView) != nil
                && self.firstSubview(of: NoteDrawingCanvasNSView.self, in: hostingView) != nil
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let canvas = try XCTUnwrap(
            firstSubview(of: NoteDrawingCanvasNSView.self, in: hostingView)
        )
        let start = canvas.convert(NSPoint(x: 80, y: 90), to: nil)
        let middle = canvas.convert(NSPoint(x: 180, y: 125), to: nil)
        let end = canvas.convert(NSPoint(x: 290, y: 80), to: nil)
        canvas.mouseDown(
            with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: start, in: window))
        )
        canvas.mouseDragged(
            with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: middle, in: window))
        )
        canvas.mouseUp(
            with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: end, in: window))
        )
        try await waitUntil("the drawn stroke to reach the note document") {
            noteSession.document.drawing.strokes.count == 1
        }
        try await waitUntil("the drawing to autosave") {
            guard let saved = try? noteStore.load(noteID: note.id) else {
                return false
            }
            return saved.drawing.strokes.count == 1
        }
        let savedNote = try XCTUnwrap(noteStore.load(noteID: note.id))
        XCTAssertEqual(
            NoteRichTextArchive.attributedString(from: savedNote.richTextRTF).string,
            "Concept notes"
        )
        let attachment = XCTAttachment(image: try renderedImage(of: hostingView))
        attachment.name = "Project note split mode"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.setContentSize(NSSize(width: 760, height: 480))
        try await Task.sleep(nanoseconds: 50_000_000)
        let compactAttachment = XCTAttachment(image: try renderedImage(of: hostingView))
        compactAttachment.name = "Project note compact split mode"
        compactAttachment.lifetime = .keepAlways
        add(compactAttachment)
        window.setContentSize(NSSize(width: 1_180, height: 740))

        noteSession.updateWorkspaceMode(.drawing)
        try await waitUntil("drawing-only mode to remove the text editor") {
            self.firstSubview(of: NoteDrawingCanvasNSView.self, in: hostingView) != nil
                && self.firstSubview(of: NSTextView.self, in: hostingView) == nil
        }

        store.selectSpace(withID: spaceID, inProject: projectID)
        try await waitUntil("the original terminal to reattach") {
            terminalView.isDescendant(of: hostingView)
        }

        XCTAssertTrue(sessions.terminalView(for: pane) === terminalView)
        XCTAssertTrue(notes.retainedSession(forNoteID: note.id) === noteSession)
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

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.8
        )
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - startedAt >= timeoutNanoseconds {
                XCTFail("Timed out waiting for \(description).")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class ProjectNotesWorkspacePersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
