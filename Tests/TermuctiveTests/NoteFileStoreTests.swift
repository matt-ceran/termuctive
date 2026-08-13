import XCTest

@testable import Termuctive

final class NoteFileStoreTests: XCTestCase {
    func testNoteRoundTripPreservesRichTextDrawingAndLayout() throws {
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let noteID = UUID()
        let stroke = NoteDrawingStroke(
            style: .marker,
            color: .blue,
            width: 8,
            points: [
                NoteDrawingPoint(x: 0.1, y: 0.2, pressure: 0.4),
                NoteDrawingPoint(x: 0.8, y: 0.7, pressure: 0.9),
            ]
        )
        let document = NoteDocument(
            noteID: noteID,
            richTextRTF: Data("rich text".utf8),
            drawing: NoteDrawing(strokes: [stroke], showsGrid: true),
            workspaceMode: .split,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let store = NoteFileStore(directoryURL: directory)

        try store.save(document)

        XCTAssertEqual(try store.load(noteID: noteID), document)
    }

    func testArchivingMovesTheNoteOutOfTheActiveDirectory() throws {
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let noteID = UUID()
        let store = NoteFileStore(directoryURL: directory)
        try store.save(NoteDocument(noteID: noteID, richTextRTF: Data("saved".utf8)))

        try store.archive(noteID: noteID)

        XCTAssertNil(try store.load(noteID: noteID))
        let archivedFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Recently Deleted", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(archivedFiles.count, 1)
        XCTAssertTrue(archivedFiles[0].lastPathComponent.hasPrefix(noteID.uuidString))
    }

    func testRepeatedArchivesOfTheSameNoteKeepEveryRecoveryCopy() throws {
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let noteID = UUID()
        let store = NoteFileStore(directoryURL: directory)

        try store.save(NoteDocument(noteID: noteID, richTextRTF: Data("first".utf8)))
        try store.archive(noteID: noteID)
        try store.save(NoteDocument(noteID: noteID, richTextRTF: Data("second".utf8)))
        try store.archive(noteID: noteID)

        let archivedFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Recently Deleted", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(archivedFiles.count, 2)
        XCTAssertTrue(
            archivedFiles.allSatisfy { $0.lastPathComponent.hasPrefix(noteID.uuidString) }
        )
    }

    func testMismatchedNoteIdentifierIsRejected() throws {
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let savedID = UUID()
        let requestedID = UUID()
        let store = NoteFileStore(directoryURL: directory)
        try store.save(NoteDocument(noteID: savedID))
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("\(savedID.uuidString).json"),
            to: directory.appendingPathComponent("\(requestedID.uuidString).json")
        )

        XCTAssertThrowsError(try store.load(noteID: requestedID)) { error in
            guard case NoteFileStoreError.mismatchedIdentifier = error else {
                return XCTFail("Expected a mismatched note identifier error.")
            }
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "termuctive-notes-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
