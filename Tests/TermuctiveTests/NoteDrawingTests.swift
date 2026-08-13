import XCTest

@testable import Termuctive

@MainActor
final class NoteDrawingTests: XCTestCase {
    func testPenMarkerUndoRedoAndClearPreserveVectorStrokes() throws {
        let controller = NoteDrawingController(drawing: NoteDrawing())
        var publishedDrawings: [NoteDrawing] = []
        controller.onDrawingChange = { publishedDrawings.append($0) }

        controller.tool = .pen
        controller.color = .red
        controller.lineWidth = 4
        controller.appendStroke(points: [
            NoteDrawingPoint(x: 0.1, y: 0.1),
            NoteDrawingPoint(x: 0.4, y: 0.5),
        ])
        controller.tool = .marker
        controller.appendStroke(points: [
            NoteDrawingPoint(x: 0.2, y: 0.8),
            NoteDrawingPoint(x: 0.9, y: 0.8),
        ])

        XCTAssertEqual(controller.drawing.strokes.map(\.style), [.pen, .marker])
        XCTAssertTrue(controller.canUndo)

        controller.undo()
        XCTAssertEqual(controller.drawing.strokes.count, 1)
        XCTAssertTrue(controller.canRedo)

        controller.redo()
        XCTAssertEqual(controller.drawing.strokes.count, 2)

        controller.clear()
        XCTAssertTrue(controller.drawing.strokes.isEmpty)
        controller.undo()
        XCTAssertEqual(controller.drawing.strokes.count, 2)
        XCTAssertFalse(publishedDrawings.isEmpty)
    }

    func testEraserGroupsSeveralRemovedStrokesIntoOneUndoOperation() throws {
        let first = NoteDrawingStroke(
            style: .pen,
            color: .black,
            width: 2,
            points: [NoteDrawingPoint(x: 0.1, y: 0.1)]
        )
        let second = NoteDrawingStroke(
            style: .pen,
            color: .black,
            width: 2,
            points: [NoteDrawingPoint(x: 0.9, y: 0.9)]
        )
        let controller = NoteDrawingController(
            drawing: NoteDrawing(strokes: [first, second])
        )

        controller.beginErasing()
        controller.erase(strokeIDs: [first.id])
        controller.erase(strokeIDs: [second.id])
        controller.finishErasing()

        XCTAssertTrue(controller.drawing.strokes.isEmpty)
        controller.undo()
        XCTAssertEqual(Set(controller.drawing.strokes.map(\.id)), [first.id, second.id])
        XCTAssertFalse(controller.canUndo)
    }

    func testDrawingPointsAndWidthsAreClampedToSafeBounds() {
        let point = NoteDrawingPoint(x: -1, y: 2, pressure: 4)
        let stroke = NoteDrawingStroke(
            style: .pen,
            color: .black,
            width: 100,
            points: [point]
        )

        XCTAssertEqual(point.x, 0)
        XCTAssertEqual(point.y, 1)
        XCTAssertEqual(point.pressure, 1)
        XCTAssertEqual(stroke.width, 24)
    }
}
