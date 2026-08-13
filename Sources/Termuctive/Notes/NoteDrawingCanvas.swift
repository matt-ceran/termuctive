import AppKit
import SwiftUI

@MainActor
final class NoteDrawingController: ObservableObject {
    @Published private(set) var drawing: NoteDrawing
    @Published var tool: NoteDrawingTool = .pen
    @Published var color: NoteRGBAColor = .black
    @Published var lineWidth = 3.0

    var onDrawingChange: ((NoteDrawing) -> Void)?

    private var undoStack: [NoteDrawing] = []
    private var redoStack: [NoteDrawing] = []
    private var erasingBaseline: NoteDrawing?

    init(drawing: NoteDrawing) {
        self.drawing = drawing
    }

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    func appendStroke(points: [NoteDrawingPoint]) {
        guard !points.isEmpty,
            tool != .eraser
        else {
            return
        }
        recordUndoSnapshot()
        let stroke = NoteDrawingStroke(
            style: tool == .marker ? .marker : .pen,
            color: color,
            width: lineWidth,
            points: points
        )
        drawing.strokes.append(stroke)
        publishChange()
    }

    func beginErasing() {
        guard erasingBaseline == nil else {
            return
        }
        erasingBaseline = drawing
    }

    func erase(strokeIDs: Set<UUID>) {
        guard !strokeIDs.isEmpty else {
            return
        }
        let remaining = drawing.strokes.filter { !strokeIDs.contains($0.id) }
        guard remaining.count != drawing.strokes.count else {
            return
        }
        drawing.strokes = remaining
        publishChange()
    }

    func finishErasing() {
        guard let baseline = erasingBaseline else {
            return
        }
        erasingBaseline = nil
        guard baseline != drawing else {
            return
        }
        undoStack.append(baseline)
        trimUndoHistory()
        redoStack.removeAll()
        objectWillChange.send()
    }

    func setGridVisible(_ isVisible: Bool) {
        guard drawing.showsGrid != isVisible else {
            return
        }
        recordUndoSnapshot()
        drawing.showsGrid = isVisible
        publishChange()
    }

    func clear() {
        guard !drawing.strokes.isEmpty else {
            return
        }
        recordUndoSnapshot()
        drawing.strokes.removeAll()
        publishChange()
    }

    func undo() {
        guard let previous = undoStack.popLast() else {
            return
        }
        redoStack.append(drawing)
        drawing = previous
        publishChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else {
            return
        }
        undoStack.append(drawing)
        trimUndoHistory()
        drawing = next
        publishChange()
    }

    private func recordUndoSnapshot() {
        undoStack.append(drawing)
        trimUndoHistory()
        redoStack.removeAll()
    }

    private func trimUndoHistory() {
        let maximumSnapshots = 60
        if undoStack.count > maximumSnapshots {
            undoStack.removeFirst(undoStack.count - maximumSnapshots)
        }
    }

    private func publishChange() {
        onDrawingChange?(drawing)
    }
}

struct NoteDrawingCanvasView: NSViewRepresentable {
    @ObservedObject var controller: NoteDrawingController

    func makeNSView(context: Context) -> NoteDrawingCanvasNSView {
        let view = NoteDrawingCanvasNSView(frame: .zero)
        view.controller = controller
        return view
    }

    func updateNSView(_ view: NoteDrawingCanvasNSView, context: Context) {
        view.controller = controller
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

@MainActor
final class NoteDrawingCanvasNSView: NSView {
    weak var controller: NoteDrawingController? {
        didSet {
            needsDisplay = true
        }
    }

    private var currentPoints: [NoteDrawingPoint] = []

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Note drawing canvas")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Note drawing canvas")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.setFill()
        bounds.fill()
        if controller?.drawing.showsGrid == true {
            drawGrid()
        }
        for stroke in controller?.drawing.strokes ?? [] {
            draw(stroke)
        }
        if !currentPoints.isEmpty,
            let controller,
            controller.tool != .eraser
        {
            draw(
                NoteDrawingStroke(
                    style: controller.tool == .marker ? .marker : .pen,
                    color: controller.color,
                    width: controller.lineWidth,
                    points: currentPoints
                )
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let controller else {
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        if controller.tool == .eraser {
            controller.beginErasing()
            erase(at: location)
        } else {
            currentPoints = [normalizedPoint(at: location, event: event)]
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller else {
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        if controller.tool == .eraser {
            erase(at: location)
        } else {
            currentPoints.append(normalizedPoint(at: location, event: event))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else {
            currentPoints.removeAll()
            return
        }
        if controller.tool == .eraser {
            controller.finishErasing()
        } else {
            let location = convert(event.locationInWindow, from: nil)
            currentPoints.append(normalizedPoint(at: location, event: event))
            controller.appendStroke(points: currentPoints)
            currentPoints.removeAll()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "z"
        else {
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.contains(.shift) {
            controller?.redo()
        } else {
            controller?.undo()
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func normalizedPoint(at point: NSPoint, event: NSEvent) -> NoteDrawingPoint {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let reportedPressure = Double(event.pressure)
        return NoteDrawingPoint(
            x: Double((point.x - bounds.minX) / width),
            y: Double((point.y - bounds.minY) / height),
            pressure: reportedPressure > 0 ? reportedPressure : 1
        )
    }

    private func denormalizedPoint(_ point: NoteDrawingPoint) -> NSPoint {
        NSPoint(
            x: bounds.minX + bounds.width * CGFloat(point.x),
            y: bounds.minY + bounds.height * CGFloat(point.y)
        )
    }

    private func draw(_ stroke: NoteDrawingStroke) {
        guard let first = stroke.points.first else {
            return
        }
        let color = stroke.color.nsColor.withAlphaComponent(
            stroke.style == .marker
                ? CGFloat(stroke.color.alpha * 0.24) : CGFloat(stroke.color.alpha)
        )
        color.setStroke()
        color.setFill()

        if stroke.points.count == 1 {
            let point = denormalizedPoint(first)
            let radius = CGFloat(stroke.width) / 2
            NSBezierPath(
                ovalIn: NSRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            ).fill()
            return
        }

        for index in 1..<stroke.points.count {
            let previous = stroke.points[index - 1]
            let current = stroke.points[index]
            let path = NSBezierPath()
            path.move(to: denormalizedPoint(previous))
            path.line(to: denormalizedPoint(current))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let pressure = (previous.pressure + current.pressure) / 2
            path.lineWidth = CGFloat(stroke.width * (0.65 + pressure * 0.35))
            path.stroke()
        }
    }

    private func drawGrid() {
        let spacing: CGFloat = 24
        let gridColor = NSColor(calibratedWhite: 0.86, alpha: 0.55)
        gridColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        var x = bounds.minX + spacing
        while x < bounds.maxX {
            path.move(to: NSPoint(x: x, y: bounds.minY))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
            x += spacing
        }
        var y = bounds.minY + spacing
        while y < bounds.maxY {
            path.move(to: NSPoint(x: bounds.minX, y: y))
            path.line(to: NSPoint(x: bounds.maxX, y: y))
            y += spacing
        }
        path.stroke()
    }

    private func erase(at location: NSPoint) {
        guard let controller else {
            return
        }
        let tolerance = max(CGFloat(controller.lineWidth), 10)
        let strokeIDs = Set(
            controller.drawing.strokes.compactMap { stroke in
                strokeIsNear(stroke, location: location, tolerance: tolerance)
                    ? stroke.id
                    : nil
            }
        )
        controller.erase(strokeIDs: strokeIDs)
        needsDisplay = true
    }

    private func strokeIsNear(
        _ stroke: NoteDrawingStroke,
        location: NSPoint,
        tolerance: CGFloat
    ) -> Bool {
        let points = stroke.points.map(denormalizedPoint)
        guard let first = points.first else {
            return false
        }
        if points.count == 1 {
            return distance(from: location, to: first) <= tolerance
        }
        for index in 1..<points.count {
            if distance(
                from: location,
                toSegmentFrom: points[index - 1],
                to: points[index]
            ) <= tolerance {
                return true
            }
        }
        return false
    }

    private func distance(from first: NSPoint, to second: NSPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func distance(
        from point: NSPoint,
        toSegmentFrom start: NSPoint,
        to end: NSPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return distance(from: point, to: start)
        }
        let projection = min(
            max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0),
            1
        )
        let nearest = NSPoint(
            x: start.x + projection * dx,
            y: start.y + projection * dy
        )
        return distance(from: point, to: nearest)
    }
}

extension NoteRGBAColor {
    var nsColor: NSColor {
        NSColor(
            calibratedRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.deviceRGB) ?? .black
        self.init(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }
}
