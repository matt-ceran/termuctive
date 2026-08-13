import Foundation

enum NoteWorkspaceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case split
    case drawing

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .text:
            "Text"
        case .split:
            "Split"
        case .drawing:
            "Draw"
        }
    }
}

struct NoteRGBAColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    static let black = NoteRGBAColor(red: 0.08, green: 0.08, blue: 0.08)
    static let graphite = NoteRGBAColor(red: 0.28, green: 0.28, blue: 0.30)
    static let blue = NoteRGBAColor(red: 0.12, green: 0.32, blue: 0.72)
    static let red = NoteRGBAColor(red: 0.72, green: 0.16, blue: 0.14)
    static let green = NoteRGBAColor(red: 0.10, green: 0.48, blue: 0.24)
    static let amber = NoteRGBAColor(red: 0.76, green: 0.48, blue: 0.08)
}

enum NoteDrawingTool: String, CaseIterable, Identifiable {
    case pen
    case marker
    case eraser

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .pen:
            "Pen"
        case .marker:
            "Marker"
        case .eraser:
            "Eraser"
        }
    }

    var systemImage: String {
        switch self {
        case .pen:
            "pencil.tip"
        case .marker:
            "highlighter"
        case .eraser:
            "eraser"
        }
    }
}

enum NoteInkStyle: String, Codable, Equatable, Sendable {
    case pen
    case marker
}

struct NoteDrawingPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var pressure: Double

    init(x: Double, y: Double, pressure: Double = 1) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.pressure = min(max(pressure, 0.1), 1)
    }
}

struct NoteDrawingStroke: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var style: NoteInkStyle
    var color: NoteRGBAColor
    var width: Double
    var points: [NoteDrawingPoint]

    init(
        id: UUID = UUID(),
        style: NoteInkStyle,
        color: NoteRGBAColor,
        width: Double,
        points: [NoteDrawingPoint]
    ) {
        self.id = id
        self.style = style
        self.color = color
        self.width = min(max(width, 1), 24)
        self.points = points
    }
}

struct NoteDrawing: Codable, Equatable, Sendable {
    var strokes: [NoteDrawingStroke]
    var showsGrid: Bool

    init(strokes: [NoteDrawingStroke] = [], showsGrid: Bool = false) {
        self.strokes = strokes
        self.showsGrid = showsGrid
    }
}

struct NoteDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let noteID: UUID
    var richTextRTF: Data
    var drawing: NoteDrawing
    var workspaceMode: NoteWorkspaceMode
    var updatedAt: Date

    init(
        schemaVersion: Int = currentSchemaVersion,
        noteID: UUID,
        richTextRTF: Data = Data(),
        drawing: NoteDrawing = NoteDrawing(),
        workspaceMode: NoteWorkspaceMode = .text,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.noteID = noteID
        self.richTextRTF = richTextRTF
        self.drawing = drawing
        self.workspaceMode = workspaceMode
        self.updatedAt = updatedAt
    }
}
