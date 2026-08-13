import AppKit
import SwiftUI

struct ProjectNoteView: View {
    let note: ProjectNote
    @ObservedObject var session: NoteDocumentSession

    @StateObject private var richTextController: NoteRichTextController
    @StateObject private var drawingController: NoteDrawingController
    @State private var isConfirmingClear = false

    init(note: ProjectNote, session: NoteDocumentSession) {
        self.note = note
        _session = ObservedObject(wrappedValue: session)
        _richTextController = StateObject(wrappedValue: NoteRichTextController())
        _drawingController = StateObject(
            wrappedValue: NoteDrawingController(drawing: session.document.drawing)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            noteToolbar
            Divider()
            noteContent
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            drawingController.onDrawingChange = { drawing in
                session.updateDrawing(drawing)
            }
        }
        .onDisappear {
            try? session.saveNow()
        }
        .alert("Clear the drawing?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Drawing", role: .destructive) {
                drawingController.clear()
            }
        } message: {
            Text(
                "This removes every stroke from this note. You can undo while the note remains open."
            )
        }
    }

    private var noteToolbar: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                fullEditorControls
                    .fixedSize(horizontal: true, vertical: false)
                compactEditorControls
            }
            .padding(.leading, 7)

            Divider()
                .frame(height: 22)

            saveStatus

            Picker("Note layout", selection: workspaceModeBinding) {
                ForEach(NoteWorkspaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
            .accessibilityLabel("Note layout")
            .padding(.trailing, 7)
        }
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var fullEditorControls: some View {
        HStack(spacing: 5) {
            if showsTextEditor {
                textFormattingControls
            }
            if session.document.workspaceMode == .split {
                Divider()
                    .frame(height: 22)
                    .padding(.horizontal, 2)
            }
            if showsDrawingEditor {
                drawingControls
            }
        }
    }

    private var compactEditorControls: some View {
        HStack(spacing: 4) {
            if showsTextEditor {
                Menu {
                    compactTextMenuContent
                } label: {
                    Label("Text", systemImage: "textformat")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Text formatting")
            }
            if showsDrawingEditor {
                Menu {
                    compactDrawingMenuContent
                } label: {
                    Label("Draw", systemImage: "pencil.and.outline")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Drawing tools")
            }
        }
    }

    @ViewBuilder
    private var compactTextMenuContent: some View {
        Menu("Style") {
            ForEach(NoteTextStyle.allCases) { style in
                Button(style.title) {
                    richTextController.applyStyle(style)
                }
            }
        }
        Menu("Font") {
            ForEach(NoteRichTextController.availableFontFamilies, id: \.self) { family in
                Button(family) {
                    richTextController.setFontFamily(family)
                }
            }
        }
        Menu("Size") {
            ForEach([9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64], id: \.self) { size in
                Button("\(size) pt") {
                    richTextController.setFontSize(Double(size))
                }
            }
        }
        ColorPicker("Text Color", selection: textColorBinding, supportsOpacity: false)
        Divider()
        Button("Bold", action: richTextController.toggleBold)
        Button("Italic", action: richTextController.toggleItalic)
        Button("Underline", action: richTextController.toggleUnderline)
        Button("Strikethrough", action: richTextController.toggleStrikethrough)
        Menu("Alignment") {
            ForEach(NoteTextAlignment.allCases) { alignment in
                Button(alignment.title) {
                    richTextController.setAlignment(alignment)
                }
            }
        }
        Button("Insert Bullet", action: richTextController.insertBullet)
        Button("Insert Numbered Item", action: richTextController.insertNumberedItem)
        Divider()
        Button("Undo Text Edit", action: richTextController.undo)
            .disabled(!richTextController.canUndo)
        Button("Redo Text Edit", action: richTextController.redo)
            .disabled(!richTextController.canRedo)
    }

    @ViewBuilder
    private var compactDrawingMenuContent: some View {
        Picker("Tool", selection: $drawingController.tool) {
            ForEach(NoteDrawingTool.allCases) { tool in
                Text(tool.title).tag(tool)
            }
        }
        ColorPicker("Ink Color", selection: inkColorBinding, supportsOpacity: false)
            .disabled(drawingController.tool == .eraser)
        Picker("Line Width", selection: $drawingController.lineWidth) {
            ForEach([2, 3, 5, 8, 12, 18], id: \.self) { width in
                Text("\(width) pt").tag(Double(width))
            }
        }
        .disabled(drawingController.tool == .eraser)
        Toggle(
            "Show Grid",
            isOn: Binding(
                get: { drawingController.drawing.showsGrid },
                set: drawingController.setGridVisible
            )
        )
        Divider()
        Button("Undo Drawing", action: drawingController.undo)
            .disabled(!drawingController.canUndo)
        Button("Redo Drawing", action: drawingController.redo)
            .disabled(!drawingController.canRedo)
        Button("Clear Drawing", role: .destructive) {
            isConfirmingClear = true
        }
        .disabled(drawingController.drawing.strokes.isEmpty)
    }

    @ViewBuilder
    private var textFormattingControls: some View {
        Menu {
            ForEach(NoteTextStyle.allCases) { style in
                Button(style.title) {
                    richTextController.applyStyle(style)
                }
            }
        } label: {
            Text(richTextController.selectedStyle.title)
                .frame(minWidth: 62, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .help("Paragraph style")

        Menu {
            ForEach(NoteRichTextController.availableFontFamilies, id: \.self) { family in
                Button(family) {
                    richTextController.setFontFamily(family)
                }
            }
        } label: {
            Text(richTextController.fontFamily)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .help("Font family")

        Menu {
            ForEach([9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64], id: \.self) { size in
                Button("\(size) pt") {
                    richTextController.setFontSize(Double(size))
                }
            }
        } label: {
            Text("\(Int(richTextController.fontSize.rounded()))")
                .monospacedDigit()
                .frame(width: 28)
        }
        .menuStyle(.borderlessButton)
        .help("Font size")

        formattingButton(
            systemImage: "bold",
            active: richTextController.isBold,
            help: "Bold",
            action: richTextController.toggleBold
        )
        formattingButton(
            systemImage: "italic",
            active: richTextController.isItalic,
            help: "Italic",
            action: richTextController.toggleItalic
        )
        formattingButton(
            systemImage: "underline",
            active: richTextController.isUnderlined,
            help: "Underline",
            action: richTextController.toggleUnderline
        )
        formattingButton(
            systemImage: "strikethrough",
            active: richTextController.isStruckThrough,
            help: "Strikethrough",
            action: richTextController.toggleStrikethrough
        )

        ColorPicker("Text color", selection: textColorBinding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24)
            .help("Text color")

        Menu {
            ForEach(NoteTextAlignment.allCases) { alignment in
                Button {
                    richTextController.setAlignment(alignment)
                } label: {
                    Label(alignment.title, systemImage: alignment.systemImage)
                }
            }
        } label: {
            Image(systemName: richTextController.alignment.systemImage)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 25)
        .help("Text alignment")

        formattingButton(
            systemImage: "list.bullet",
            active: false,
            help: "Insert bullet",
            action: richTextController.insertBullet
        )
        formattingButton(
            systemImage: "list.number",
            active: false,
            help: "Insert numbered item",
            action: richTextController.insertNumberedItem
        )

        formattingButton(
            systemImage: "arrow.uturn.backward",
            active: false,
            help: "Undo text edit",
            action: richTextController.undo
        )
        .disabled(!richTextController.canUndo)
        formattingButton(
            systemImage: "arrow.uturn.forward",
            active: false,
            help: "Redo text edit",
            action: richTextController.redo
        )
        .disabled(!richTextController.canRedo)
    }

    @ViewBuilder
    private var drawingControls: some View {
        Picker("Drawing tool", selection: $drawingController.tool) {
            ForEach(NoteDrawingTool.allCases) { tool in
                Image(systemName: tool.systemImage)
                    .tag(tool)
                    .help(tool.title)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 96)
        .accessibilityLabel("Drawing tool")

        ColorPicker("Ink color", selection: inkColorBinding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24)
            .disabled(drawingController.tool == .eraser)
            .help("Ink color")

        Image(systemName: "line.diagonal")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        Slider(value: $drawingController.lineWidth, in: 1...18, step: 1)
            .frame(width: 72)
            .disabled(drawingController.tool == .eraser)
            .help("Stroke width")

        formattingButton(
            systemImage: drawingController.drawing.showsGrid ? "grid" : "square",
            active: drawingController.drawing.showsGrid,
            help: "Toggle drawing grid"
        ) {
            drawingController.setGridVisible(!drawingController.drawing.showsGrid)
        }
        formattingButton(
            systemImage: "arrow.uturn.backward",
            active: false,
            help: "Undo drawing",
            action: drawingController.undo
        )
        .disabled(!drawingController.canUndo)
        formattingButton(
            systemImage: "arrow.uturn.forward",
            active: false,
            help: "Redo drawing",
            action: drawingController.redo
        )
        .disabled(!drawingController.canRedo)
        formattingButton(
            systemImage: "trash",
            active: false,
            help: "Clear drawing"
        ) {
            isConfirmingClear = true
        }
        .disabled(drawingController.drawing.strokes.isEmpty)
    }

    @ViewBuilder
    private var noteContent: some View {
        switch session.document.workspaceMode {
        case .text:
            richTextEditor
        case .drawing:
            drawingEditor
        case .split:
            HSplitView {
                richTextEditor
                    .frame(minWidth: 300)
                drawingEditor
                    .frame(minWidth: 260)
            }
        }
    }

    private var richTextEditor: some View {
        NoteRichTextEditorView(
            rtfData: session.document.richTextRTF,
            controller: richTextController,
            onChange: session.updateRichText
        )
        .accessibilityLabel("\(note.name) text")
    }

    private var drawingEditor: some View {
        NoteDrawingCanvasView(controller: drawingController)
            .overlay {
                Rectangle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("\(note.name) drawing")
    }

    private var workspaceModeBinding: Binding<NoteWorkspaceMode> {
        Binding(
            get: { session.document.workspaceMode },
            set: session.updateWorkspaceMode
        )
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: richTextController.textColor.nsColor) },
            set: { color in
                richTextController.setTextColor(
                    NoteRGBAColor(nsColor: NSColor(color))
                )
            }
        )
    }

    private var inkColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: drawingController.color.nsColor) },
            set: { color in
                drawingController.color = NoteRGBAColor(nsColor: NSColor(color))
            }
        )
    }

    private var showsTextEditor: Bool {
        session.document.workspaceMode != .drawing
    }

    private var showsDrawingEditor: Bool {
        session.document.workspaceMode != .text
    }

    private var saveStatus: some View {
        Group {
            if session.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .help("Saving note")
            } else if session.errorMessage != nil {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(session.errorMessage ?? "Note save failed")
            } else if session.isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved note changes")
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Note saved")
            }
        }
        .frame(width: 18, height: 24)
        .accessibilityLabel(session.isDirty ? "Note has unsaved changes" : "Note saved")
    }

    private func formattingButton(
        systemImage: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .background(active ? Color.primary.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
