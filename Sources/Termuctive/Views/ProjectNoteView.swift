import AppKit
import SwiftUI

enum NoteToolbarLayout: Equatable {
    case expanded
    case regular
    case compact
    case narrow
    case minimal

    static func resolve(width: CGFloat, mode: NoteWorkspaceMode) -> NoteToolbarLayout {
        let expandedMinimum: CGFloat
        switch mode {
        case .text:
            expandedMinimum = 900
        case .drawing:
            expandedMinimum = 760
        case .split:
            expandedMinimum = 1_240
        }
        if width >= expandedMinimum {
            return .expanded
        }
        if width >= 680 {
            return .regular
        }
        if width >= 410 {
            return .compact
        }
        if width >= 180 {
            return .narrow
        }
        return .minimal
    }
}

private enum NoteActiveSurface {
    case text
    case drawing
}

struct ProjectNoteView: View {
    let note: ProjectNote
    @ObservedObject var session: NoteDocumentSession
    let onFocus: () -> Void
    let isPaneFocused: Bool

    @StateObject private var richTextController: NoteRichTextController
    @StateObject private var drawingController: NoteDrawingController
    @State private var isConfirmingClear = false
    @State private var activeSurface = NoteActiveSurface.text
    @Environment(\.colorScheme) private var colorScheme

    init(
        note: ProjectNote,
        session: NoteDocumentSession,
        onFocus: @escaping () -> Void = {},
        isPaneFocused: Bool = false
    ) {
        self.note = note
        self.onFocus = onFocus
        self.isPaneFocused = isPaneFocused
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
        .background(
            Color(nsColor: NoteEditorPalette.backgroundColor(for: colorScheme))
        )
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
        GeometryReader { geometry in
            toolbarContent(
                layout: NoteToolbarLayout.resolve(
                    width: geometry.size.width,
                    mode: session.document.workspaceMode
                )
            )
        }
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("note-toolbar")
    }

    @ViewBuilder
    private func toolbarContent(layout: NoteToolbarLayout) -> some View {
        HStack(spacing: 8) {
            switch layout {
            case .expanded:
                expandedEditorControls
            case .regular:
                regularEditorControls
            case .compact:
                labeledEditorMenus
            case .narrow:
                iconEditorMenus
            case .minimal:
                minimalEditorMenu
            }

            Spacer(minLength: layout == .minimal ? 0 : 4)
            if layout != .minimal {
                saveStatus
                if layout == .narrow {
                    workspaceModeMenu
                } else {
                    workspaceModePicker(compact: layout == .compact)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
    }

    @ViewBuilder
    private var expandedEditorControls: some View {
        HStack(spacing: 8) {
            if showsTextEditor {
                toolbarGroup { typographyControls(includeFontFamily: true) }
                toolbarGroup { emphasisControls(includeStrikethrough: true) }
                toolbarGroup { paragraphControls }
                toolbarGroup { textHistoryControls }
            }
            if session.document.workspaceMode == .split {
                Divider()
                    .frame(height: 26)
            }
            if showsDrawingEditor {
                toolbarGroup { drawingControls }
            }
        }
    }

    @ViewBuilder
    private var regularEditorControls: some View {
        HStack(spacing: 8) {
            if showsTextEditor {
                toolbarGroup { typographyControls(includeFontFamily: false) }
                toolbarGroup { emphasisControls(includeStrikethrough: false) }
                Menu {
                    compactTextMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30, height: 30)
                .help("More text formatting")
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

    private var labeledEditorMenus: some View {
        editorMenus(showsLabels: true)
    }

    private var iconEditorMenus: some View {
        editorMenus(showsLabels: false)
    }

    private var minimalEditorMenu: some View {
        Menu {
            if showsTextEditor {
                Menu("Text Formatting") {
                    compactTextMenuContent
                }
            }
            if showsDrawingEditor {
                Menu("Drawing Tools") {
                    compactDrawingMenuContent
                }
            }
            Divider()
            Picker("Note Layout", selection: workspaceModeBinding) {
                ForEach(NoteWorkspaceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30, height: 30)
        .help("Note tools and layout")
        .accessibilityLabel("Note tools and layout")
    }

    private func editorMenus(showsLabels: Bool) -> some View {
        HStack(spacing: 6) {
            if showsTextEditor {
                Menu {
                    compactTextMenuContent
                } label: {
                    if showsLabels {
                        Label("Format", systemImage: "textformat")
                    } else {
                        Image(systemName: "textformat")
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(minWidth: showsLabels ? 72 : 30, minHeight: 30)
                .help("Text formatting")
            }
            if showsDrawingEditor {
                Menu {
                    compactDrawingMenuContent
                } label: {
                    if showsLabels {
                        Label("Draw", systemImage: "pencil.and.outline")
                    } else {
                        Image(systemName: "pencil.and.outline")
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(minWidth: showsLabels ? 62 : 30, minHeight: 30)
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
    private func typographyControls(includeFontFamily: Bool) -> some View {
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

        if includeFontFamily {
            Menu {
                ForEach(NoteRichTextController.availableFontFamilies, id: \.self) { family in
                    Button(family) {
                        richTextController.setFontFamily(family)
                    }
                }
            } label: {
                Text(richTextController.fontFamily)
                    .lineLimit(1)
                    .frame(width: 106, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .help("Font family")
        }

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
    }

    @ViewBuilder
    private func emphasisControls(includeStrikethrough: Bool) -> some View {
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
        if includeStrikethrough {
            formattingButton(
                systemImage: "strikethrough",
                active: richTextController.isStruckThrough,
                help: "Strikethrough",
                action: richTextController.toggleStrikethrough
            )
        }
    }

    @ViewBuilder
    private var paragraphControls: some View {
        NoteColorPicker(
            color: textColorBinding,
            accessibilityLabel: "Text color"
        )
        .frame(width: 24, height: 24)
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
    }

    @ViewBuilder
    private var textHistoryControls: some View {
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

        NoteColorPicker(
            color: inkColorBinding,
            accessibilityLabel: "Ink color"
        )
        .frame(width: 24, height: 24)
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

    private func toolbarGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 3) {
            content()
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func workspaceModePicker(compact: Bool) -> some View {
        Picker("Note layout", selection: workspaceModeBinding) {
            ForEach(NoteWorkspaceMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: compact ? 150 : 168)
        .accessibilityLabel("Note layout")
    }

    private var workspaceModeMenu: some View {
        Menu {
            Picker("Note layout", selection: workspaceModeBinding) {
                ForEach(NoteWorkspaceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
        } label: {
            Label(
                session.document.workspaceMode.title,
                systemImage: session.document.workspaceMode.systemImage
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Note layout")
        .accessibilityLabel("Note layout: \(session.document.workspaceMode.title)")
    }

    @ViewBuilder
    private var noteContent: some View {
        switch session.document.workspaceMode {
        case .text:
            richTextEditor
        case .drawing:
            drawingEditor
        case .split:
            GeometryReader { geometry in
                if geometry.size.width >= 620 {
                    HSplitView {
                        richTextEditor
                            .frame(minWidth: 240)
                        drawingEditor
                            .frame(minWidth: 220)
                    }
                } else {
                    VSplitView {
                        richTextEditor
                            .frame(minHeight: 150)
                        drawingEditor
                            .frame(minHeight: 140)
                    }
                }
            }
        }
    }

    private var richTextEditor: some View {
        NoteRichTextEditorView(
            rtfData: session.document.richTextRTF,
            controller: richTextController,
            onFocus: focusTextSurface,
            requestsFocus: textSurfaceRequestsFocus,
            onChange: session.updateRichText
        )
        .accessibilityLabel("\(note.name) text")
    }

    private var drawingEditor: some View {
        NoteDrawingCanvasView(
            controller: drawingController,
            onFocus: focusDrawingSurface,
            requestsFocus: drawingSurfaceRequestsFocus
        )
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
            get: {
                Color(
                    nsColor: NoteEditorPalette.displayColor(
                        for: richTextController.textColor,
                        colorScheme: colorScheme
                    )
                )
            },
            set: { color in
                richTextController.setTextColor(
                    NoteRGBAColor(nsColor: NSColor(color))
                )
            }
        )
    }

    private var inkColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    nsColor: NoteEditorPalette.displayColor(
                        for: drawingController.color,
                        colorScheme: colorScheme
                    )
                )
            },
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

    private var textSurfaceRequestsFocus: Bool {
        guard isPaneFocused else {
            return false
        }
        switch session.document.workspaceMode {
        case .text:
            return true
        case .split:
            return activeSurface == .text
        case .drawing:
            return false
        }
    }

    private var drawingSurfaceRequestsFocus: Bool {
        guard isPaneFocused else {
            return false
        }
        switch session.document.workspaceMode {
        case .text:
            return false
        case .split:
            return activeSurface == .drawing
        case .drawing:
            return true
        }
    }

    private func focusTextSurface() {
        activeSurface = .text
        onFocus()
    }

    private func focusDrawingSurface() {
        activeSurface = .drawing
        onFocus()
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

private struct NoteColorPicker: View {
    @Binding var color: Color
    let accessibilityLabel: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                Circle()
                    .stroke(Color.primary.opacity(0.38), lineWidth: 1)
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ColorPicker(
                accessibilityLabel,
                selection: $color,
                supportsOpacity: false
            )
            .padding(12)
            .frame(width: 220)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
