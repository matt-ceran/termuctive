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
            appearance: appearance,
            agentActivity: sessions.agentActivityRegistry
        )
        .preferredColorScheme(.dark)
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
        let textBackground = try XCTUnwrap(
            textView.backgroundColor.usingColorSpace(.deviceRGB)
        )
        let insertionColor = try XCTUnwrap(
            textView.insertionPointColor.usingColorSpace(.deviceRGB)
        )
        XCTAssertLessThan(textBackground.redComponent, 0.2)
        XCTAssertGreaterThan(insertionColor.redComponent, 0.9)
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

        store.isSidebarVisible = false
        window.setContentSize(NSSize(width: 1_440, height: 700))
        try await Task.sleep(nanoseconds: 50_000_000)
        let expandedToolbarAttachment = XCTAttachment(image: try renderedImage(of: hostingView))
        expandedToolbarAttachment.name = "Expanded dark note toolbar"
        expandedToolbarAttachment.lifetime = .keepAlways
        add(expandedToolbarAttachment)

        store.isSidebarVisible = true
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

        noteSession.updateWorkspaceMode(.split)
        let notePaneID = try XCTUnwrap(
            store.openNoteInNewPane(
                noteID: note.id,
                inProjectWithID: projectID,
                axis: .horizontal
            )
        )
        try await waitUntil("the note to render beside the original terminal") {
            terminalView.isDescendant(of: hostingView)
                && self.firstSubview(of: NSTextView.self, in: hostingView) != nil
                && self.firstSubview(of: NoteDrawingCanvasNSView.self, in: hostingView) != nil
        }
        try await waitUntil("the focused note pane to receive keyboard focus") {
            window.firstResponder is NSTextView
        }
        let renderedNotePane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: notePaneID)
        )
        XCTAssertEqual(renderedNotePane.content, .note(note.id))
        XCTAssertEqual(store.focusedPaneNote, note)
        XCTAssertEqual(store.selectedProject?.notes.filter { $0.id == note.id }.count, 1)
        XCTAssertTrue(sessions.terminalView(for: pane) === terminalView)

        sessions.focus(paneID: pane.id)
        try await waitUntil("the terminal pane to become focused") {
            store.focusedPaneID == pane.id
        }
        let focusedCanvas = try XCTUnwrap(
            firstSubview(of: NoteDrawingCanvasNSView.self, in: hostingView)
        )
        let canvasPoint = focusedCanvas.convert(NSPoint(x: 40, y: 40), to: nil)
        focusedCanvas.mouseDown(
            with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: canvasPoint, in: window))
        )
        focusedCanvas.mouseUp(
            with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: canvasPoint, in: window))
        )
        try await waitUntil("the split drawing surface to retain keyboard focus") {
            store.focusedPaneID == notePaneID
                && window.firstResponder === focusedCanvas
        }

        let notePaneAttachment = XCTAttachment(image: try renderedImage(of: hostingView))
        notePaneAttachment.name = "Dark note beside terminal"
        notePaneAttachment.lifetime = .keepAlways
        add(notePaneAttachment)

        window.setContentSize(NSSize(width: 760, height: 480))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(terminalView.isDescendant(of: hostingView))
        XCTAssertNotNil(firstSubview(of: NSTextView.self, in: hostingView))
        XCTAssertNotNil(firstSubview(of: NoteDrawingCanvasNSView.self, in: hostingView))
        let narrowNotePaneAttachment = XCTAttachment(image: try renderedImage(of: hostingView))
        narrowNotePaneAttachment.name = "Narrow dark note beside terminal"
        narrowNotePaneAttachment.lifetime = .keepAlways
        add(narrowNotePaneAttachment)

        let resizedLayout = try XCTUnwrap(store.selectedSpace?.layout)
        guard case .split(let split) = resizedLayout else {
            XCTFail("Expected the terminal and note to share a split")
            return
        }
        store.commitSplitRatio(splitID: split.id, ratio: 0.9)
        try await Task.sleep(nanoseconds: 50_000_000)
        let minimalNotePaneAttachment = XCTAttachment(image: try renderedImage(of: hostingView))
        minimalNotePaneAttachment.name = "Minimal dark note pane"
        minimalNotePaneAttachment.lifetime = .keepAlways
        add(minimalNotePaneAttachment)

        store.closePane(withID: notePaneID)
        try await waitUntil("the original terminal to remain after closing the note pane") {
            terminalView.isDescendant(of: hostingView)
                && store.selectedSpace?.layout.terminalCount == 1
        }
        XCTAssertEqual(store.selectedProject?.note(withID: note.id), note)
        XCTAssertTrue(notes.retainedSession(forNoteID: note.id) === noteSession)
    }

    func testNoteTextFollowsLightDarkLightAppearanceWithoutChangingStoredRTF() async throws {
        let note = ProjectNote(name: "Theme")
        let source = NSAttributedString(
            string: "Automatic text",
            attributes: NoteRichTextArchive.defaultBodyAttributes
        )
        let originalRTF = try NoteRichTextArchive.data(from: source)
        let persistence = ThemeNotePersistence(
            loadedDocument: NoteDocument(
                noteID: note.id,
                richTextRTF: originalRTF
            )
        )
        let session = NoteDocumentSession(noteID: note.id, persistence: persistence)
        let theme = NoteThemeModel()
        let hostingView = NSHostingView(
            rootView: NoteThemeHarness(
                note: note,
                session: session,
                theme: theme
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(firstSubview(of: NSTextView.self, in: hostingView))

        try await waitUntil("the light note palette") {
            textView.backgroundColor.usingColorSpace(.deviceRGB)?.redComponent ?? 0 > 0.9
        }
        XCTAssertNil(temporaryForegroundColor(in: textView))

        theme.scheme = .dark
        try await waitUntil("the dark note palette") {
            textView.backgroundColor.usingColorSpace(.deviceRGB)?.redComponent ?? 1 < 0.2
                && (self.temporaryForegroundColor(in: textView)?
                    .usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.9
        }

        theme.scheme = .light
        try await waitUntil("the restored light note palette") {
            textView.backgroundColor.usingColorSpace(.deviceRGB)?.redComponent ?? 0 > 0.9
                && self.temporaryForegroundColor(in: textView) == nil
        }

        XCTAssertEqual(session.document.richTextRTF, originalRTF)
        let storedColor = try XCTUnwrap(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        )
        XCTAssertLessThan(
            try XCTUnwrap(storedColor.usingColorSpace(.deviceRGB)).redComponent,
            0.2
        )
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

    private func temporaryForegroundColor(in textView: NSTextView) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 0,
            effectiveRange: nil
        ) as? NSColor
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

@MainActor
private final class NoteThemeModel: ObservableObject {
    @Published var scheme: ColorScheme = .light
}

private struct NoteThemeHarness: View {
    let note: ProjectNote
    @ObservedObject var session: NoteDocumentSession
    @ObservedObject var theme: NoteThemeModel

    var body: some View {
        ProjectNoteView(note: note, session: session)
            .preferredColorScheme(theme.scheme)
    }
}

private final class ThemeNotePersistence: NotePersisting {
    let loadedDocument: NoteDocument

    init(loadedDocument: NoteDocument) {
        self.loadedDocument = loadedDocument
    }

    func load(noteID: UUID) throws -> NoteDocument? {
        loadedDocument.noteID == noteID ? loadedDocument : nil
    }

    func save(_ document: NoteDocument) throws {}

    func archive(noteID: UUID) throws {}
}

private final class ProjectNotesWorkspacePersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
