import XCTest

@testable import Termuctive

@MainActor
final class NoteSessionPoolTests: XCTestCase {
    func testSessionSavesRichTextDrawingAndLayoutTogether() throws {
        let persistence = RecordingNotePersistence()
        let note = ProjectNote(name: "Architecture")
        let pool = NoteSessionPool(persistence: persistence)
        let session = pool.session(for: note)
        let drawing = NoteDrawing(
            strokes: [
                NoteDrawingStroke(
                    style: .pen,
                    color: .black,
                    width: 3,
                    points: [NoteDrawingPoint(x: 0.2, y: 0.3)]
                )
            ]
        )

        session.updateRichText(Data("lesson".utf8))
        session.updateDrawing(drawing)
        session.updateWorkspaceMode(.split)
        try session.saveNow()

        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(persistence.savedDocuments.count, 1)
        XCTAssertEqual(persistence.savedDocuments[0].noteID, note.id)
        XCTAssertEqual(persistence.savedDocuments[0].richTextRTF, Data("lesson".utf8))
        XCTAssertEqual(persistence.savedDocuments[0].drawing, drawing)
        XCTAssertEqual(persistence.savedDocuments[0].workspaceMode, .split)
    }

    func testPoolReusesSessionAndFlushesItDuringReconciliation() throws {
        let persistence = RecordingNotePersistence()
        let note = ProjectNote(name: "Research")
        let pool = NoteSessionPool(persistence: persistence)
        let first = pool.session(for: note)
        let second = pool.session(for: note)
        first.updateRichText(Data("pending".utf8))

        pool.reconcile(validNoteIDs: [])

        XCTAssertTrue(first === second)
        XCTAssertNil(pool.retainedSession(forNoteID: note.id))
        XCTAssertEqual(persistence.savedDocuments.last?.richTextRTF, Data("pending".utf8))
    }

    func testArchivingFlushesDirtyContentBeforeMovingTheFile() {
        let persistence = RecordingNotePersistence()
        let note = ProjectNote(name: "Meeting")
        let pool = NoteSessionPool(persistence: persistence)
        pool.session(for: note).updateRichText(Data("last edit".utf8))

        pool.archive(noteIDs: [note.id])

        XCTAssertEqual(persistence.savedDocuments.last?.richTextRTF, Data("last edit".utf8))
        XCTAssertEqual(persistence.archivedNoteIDs, [note.id])
        XCTAssertNil(pool.retainedSession(forNoteID: note.id))
    }

    func testSessionAutosavesTheLatestCombinedDocumentAfterEditsSettle() async throws {
        let persistence = RecordingNotePersistence()
        let note = ProjectNote(name: "Autosave")
        let session = NoteDocumentSession(noteID: note.id, persistence: persistence)
        let drawing = NoteDrawing(
            strokes: [
                NoteDrawingStroke(
                    style: .pen,
                    color: .black,
                    width: 3,
                    points: [NoteDrawingPoint(x: 0.3, y: 0.4)],
                )
            ]
        )

        session.updateRichText(Data("latest text".utf8))
        session.updateDrawing(drawing)
        session.updateWorkspaceMode(.split)

        let deadline = Date().addingTimeInterval(2)
        while persistence.savedDocuments.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let saved = try XCTUnwrap(persistence.savedDocuments.last)
        XCTAssertEqual(saved.richTextRTF, Data("latest text".utf8))
        XCTAssertEqual(saved.drawing, drawing)
        XCTAssertEqual(saved.workspaceMode, .split)
        XCTAssertFalse(session.isDirty)
    }
}

private final class RecordingNotePersistence: NotePersisting {
    var loadedDocuments: [UUID: NoteDocument] = [:]
    var savedDocuments: [NoteDocument] = []
    var archivedNoteIDs: [UUID] = []

    func load(noteID: UUID) throws -> NoteDocument? {
        loadedDocuments[noteID]
    }

    func save(_ document: NoteDocument) throws {
        savedDocuments.append(document)
        loadedDocuments[document.noteID] = document
    }

    func archive(noteID: UUID) throws {
        archivedNoteIDs.append(noteID)
        loadedDocuments.removeValue(forKey: noteID)
    }
}
