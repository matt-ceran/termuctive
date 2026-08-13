import AppKit
import SwiftUI

struct PaneTreeView: NSViewRepresentable {
    let node: PaneNode
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool
    @ObservedObject var editors: EditorSessionPool
    @ObservedObject var notes: NoteSessionPool

    func makeNSView(context: Context) -> PaneTreeContainerView {
        let view = PaneTreeContainerView(frame: .zero)
        view.configure(
            node: node,
            store: store,
            sessions: sessions,
            editors: editors,
            notes: notes
        )
        return view
    }

    func updateNSView(_ view: PaneTreeContainerView, context: Context) {
        view.configure(
            node: node,
            store: store,
            sessions: sessions,
            editors: editors,
            notes: notes
        )
    }
}

private enum PaneLeafPresentation: Equatable {
    case terminal
    case pdf(URL)
    case editor
    case note(UUID)
}

@MainActor
final class PaneTreeContainerView: NSView {
    private var rootController: PaneTreeNodeController?

    override var isFlipped: Bool {
        true
    }

    func configure(
        node: PaneNode,
        store: WorkspaceStore,
        sessions: TerminalSessionPool,
        editors: EditorSessionPool,
        notes: NoteSessionPool
    ) {
        if let rootController,
            rootController.matchesStructure(of: node)
        {
            rootController.update(
                node: node,
                store: store,
                sessions: sessions,
                editors: editors,
                notes: notes
            )
            return
        }

        rootController?.view.removeFromSuperview()
        let controller = PaneTreeNodeController(
            node: node,
            store: store,
            sessions: sessions,
            editors: editors,
            notes: notes
        )
        rootController = controller
        controller.view.frame = bounds
        controller.view.autoresizingMask = [.width, .height]
        addSubview(controller.view)
    }

    override func layout() {
        super.layout()
        rootController?.view.frame = bounds
    }
}

@MainActor
private final class PaneTreeNodeController {
    private enum Content {
        case terminal(
            pane: TerminalPane,
            presentation: PaneLeafPresentation,
            host: NSHostingView<AnyView>
        )
        case split(
            id: UUID,
            axis: PaneAxis,
            view: SmoothSplitView,
            first: PaneTreeNodeController,
            second: PaneTreeNodeController
        )
    }

    private var content: Content

    var view: NSView {
        switch content {
        case .terminal(_, _, let host):
            host
        case .split(_, _, let view, _, _):
            view
        }
    }

    init(
        node: PaneNode,
        store: WorkspaceStore,
        sessions: TerminalSessionPool,
        editors: EditorSessionPool,
        notes: NoteSessionPool
    ) {
        switch node {
        case .terminal(let pane):
            let presentation = Self.presentation(
                for: pane,
                sessions: sessions,
                editors: editors
            )
            let host = NSHostingView(
                rootView: Self.leafView(
                    pane: pane,
                    presentation: presentation,
                    store: store,
                    sessions: sessions,
                    editors: editors,
                    notes: notes
                )
            )
            host.sizingOptions = []
            content = .terminal(
                pane: pane,
                presentation: presentation,
                host: host
            )

        case .split(let split):
            let first = PaneTreeNodeController(
                node: split.first,
                store: store,
                sessions: sessions,
                editors: editors,
                notes: notes
            )
            let second = PaneTreeNodeController(
                node: split.second,
                store: store,
                sessions: sessions,
                editors: editors,
                notes: notes
            )
            let splitView = SmoothSplitView(axis: split.axis)
            splitView.addArrangedSubview(first.view)
            splitView.addArrangedSubview(second.view)
            splitView.setTheme(sessions.terminalTheme)
            splitView.setRatio(split.ratio)
            splitView.onRatioCommit = { [weak store] ratio in
                store?.commitSplitRatio(splitID: split.id, ratio: ratio)
            }
            content = .split(
                id: split.id,
                axis: split.axis,
                view: splitView,
                first: first,
                second: second
            )
        }
    }

    func matchesStructure(of node: PaneNode) -> Bool {
        switch (content, node) {
        case (.terminal(let pane, _, _), .terminal(let updatedPane)):
            pane.id == updatedPane.id

        case (
            .split(let id, let axis, _, let first, let second),
            .split(let updatedSplit)
        ):
            id == updatedSplit.id
                && axis == updatedSplit.axis
                && first.matchesStructure(of: updatedSplit.first)
                && second.matchesStructure(of: updatedSplit.second)

        default:
            false
        }
    }

    func update(
        node: PaneNode,
        store: WorkspaceStore,
        sessions: TerminalSessionPool,
        editors: EditorSessionPool,
        notes: NoteSessionPool
    ) {
        switch (content, node) {
        case (
            .terminal(let previousPane, let previousPresentation, let host),
            .terminal(let pane)
        ):
            let presentation = Self.presentation(
                for: pane,
                sessions: sessions,
                editors: editors
            )
            guard pane != previousPane || presentation != previousPresentation else {
                return
            }
            host.rootView = Self.leafView(
                pane: pane,
                presentation: presentation,
                store: store,
                sessions: sessions,
                editors: editors,
                notes: notes
            )
            content = .terminal(
                pane: pane,
                presentation: presentation,
                host: host
            )

        case (
            .split(let id, let axis, let splitView, let first, let second),
            .split(let split)
        ):
            guard id == split.id,
                axis == split.axis
            else {
                return
            }
            first.update(
                node: split.first,
                store: store,
                sessions: sessions,
                editors: editors,
                notes: notes
            )
            second.update(
                node: split.second,
                store: store,
                sessions: sessions,
                editors: editors,
                notes: notes
            )
            splitView.setTheme(sessions.terminalTheme)
            splitView.setRatio(split.ratio)

        default:
            return
        }
    }

    private static func presentation(
        for pane: TerminalPane,
        sessions: TerminalSessionPool,
        editors: EditorSessionPool
    ) -> PaneLeafPresentation {
        if let previewURL = sessions.previewURL(for: pane.id) {
            return .pdf(previewURL)
        }
        if editors.isEditorPresented(inPaneID: pane.id) {
            return .editor
        }
        if case .note(let noteID) = pane.content {
            return .note(noteID)
        }
        return .terminal
    }

    private static func leafView(
        pane: TerminalPane,
        presentation: PaneLeafPresentation,
        store: WorkspaceStore,
        sessions: TerminalSessionPool,
        editors: EditorSessionPool,
        notes: NoteSessionPool
    ) -> AnyView {
        if presentation == .editor,
            let editorSession = editors.session(forPaneID: pane.id)
        {
            return AnyView(
                EditorPaneContainerView(
                    pane: pane,
                    store: store,
                    terminalSessions: sessions,
                    editorSessions: editors,
                    session: editorSession
                )
                .id(pane.id)
            )
        }
        if case .note(let noteID) = presentation,
            let note = store.document.note(withID: noteID)
        {
            return AnyView(
                NotePaneContainerView(
                    pane: pane,
                    noteID: note.id,
                    store: store,
                    terminalSessions: sessions,
                    editorSessions: editors,
                    noteSession: notes.session(for: note)
                )
                .id(pane.id)
            )
        }
        return AnyView(
            TerminalPaneView(
                pane: pane,
                store: store,
                sessions: sessions,
                editors: editors
            )
            .id(pane.id)
        )
    }
}

private struct NotePaneContainerView: View {
    let pane: TerminalPane
    let noteID: UUID
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var terminalSessions: TerminalSessionPool
    @ObservedObject var editorSessions: EditorSessionPool
    @ObservedObject var noteSession: NoteDocumentSession

    var body: some View {
        Group {
            if let note = store.document.note(withID: noteID) {
                notePane(note)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(noteName) note pane")
    }

    private func notePane(_ note: ProjectNote) -> some View {
        VStack(spacing: 0) {
            notePaneHeader(note)
                .frame(height: 28)
                .background(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture(perform: focusPane)

            ProjectNoteView(
                note: note,
                session: noteSession,
                onFocus: focusPane,
                isPaneFocused: store.focusedPaneID == pane.id
            )
        }
    }

    private func notePaneHeader(_ note: ProjectNote) -> some View {
        GeometryReader { geometry in
            HStack(spacing: geometry.size.width >= 120 ? 8 : 4) {
                if geometry.size.width >= 120 {
                    Image(systemName: "note.text")
                        .font(.system(size: 11, weight: .medium))
                    Text(note.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                } else {
                    Spacer(minLength: 0)
                }

                Button {
                    store.showTerminal(inPaneWithID: pane.id)
                    terminalSessions.focus(paneID: pane.id)
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.plain)
                .help("Return to Terminal")
                .accessibilityLabel("Return note pane to terminal")

                Button {
                    editorSessions.requestClosePane(withID: pane.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Pane")
                .accessibilityLabel("Close note pane")
            }
            .font(.system(size: 11))
            .padding(.horizontal, geometry.size.width >= 120 ? 9 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noteName: String {
        store.document.note(withID: noteID)?.name ?? "Note"
    }

    private func focusPane() {
        store.focusPane(withID: pane.id)
    }
}

private struct TerminalPaneView: View {
    let pane: TerminalPane
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool
    @ObservedObject var editors: EditorSessionPool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: previewURL == nil ? "terminal" : "doc.richtext")
                    .font(.system(size: 11, weight: .medium))
                Text(previewURL?.lastPathComponent ?? sessions.title(for: pane))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(displayedPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if sessions.isFindingPDF(for: pane.id) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Finding the most recent PDF")
                }

                if let previewURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([previewURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal PDF in Finder")
                    .accessibilityLabel("Reveal PDF in Finder")

                    Button {
                        sessions.dismissPDFPreview(inPaneID: pane.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .help(
                        editors.isEditorPresented(inPaneID: pane.id)
                            ? "Return to IDE"
                            : "Return to Terminal"
                    )
                    .accessibilityLabel(
                        editors.isEditorPresented(inPaneID: pane.id)
                            ? "Return to IDE"
                            : "Return to terminal"
                    )
                } else {
                    Button {
                        editors.presentEditor(inPaneID: pane.id)
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.plain)
                    .help("Open IDE")
                    .accessibilityLabel("Open IDE")

                    if case .exited = sessions.status(for: pane.id) {
                        Button {
                            sessions.restart(pane: pane)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Restart Terminal")
                        .accessibilityLabel("Restart terminal")
                    }
                }

                Button {
                    editors.requestClosePane(withID: pane.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Pane")
                .accessibilityLabel("Close pane")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture {
                focusPane()
            }

            if let previewURL {
                PDFPaneView(url: previewURL) {
                    store.focusPane(withID: pane.id)
                }
            } else {
                TerminalHostView(
                    pane: pane,
                    isFocused: store.focusedPaneID == pane.id,
                    sessions: sessions
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var previewURL: URL? {
        sessions.previewURL(for: pane.id)
    }

    private var displayedPath: String {
        abbreviatedPath(
            previewURL?.deletingLastPathComponent().path
                ?? pane.workingDirectory
        )
    }

    private var accessibilityLabel: String {
        if let previewURL {
            return "\(previewURL.lastPathComponent) PDF preview"
        }
        return "\(sessions.title(for: pane)) terminal"
    }

    private func focusPane() {
        if previewURL == nil {
            sessions.focus(paneID: pane.id)
        } else {
            store.focusPane(withID: pane.id)
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }
}
