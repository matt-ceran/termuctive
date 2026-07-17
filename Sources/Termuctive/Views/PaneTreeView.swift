import AppKit
import SwiftUI

struct PaneTreeView: NSViewRepresentable {
    let node: PaneNode
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool

    func makeNSView(context: Context) -> PaneTreeContainerView {
        let view = PaneTreeContainerView(frame: .zero)
        view.configure(node: node, store: store, sessions: sessions)
        return view
    }

    func updateNSView(_ view: PaneTreeContainerView, context: Context) {
        view.configure(node: node, store: store, sessions: sessions)
    }
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
        sessions: TerminalSessionPool
    ) {
        if let rootController,
            rootController.matchesStructure(of: node)
        {
            rootController.update(node: node, store: store, sessions: sessions)
            return
        }

        rootController?.view.removeFromSuperview()
        let controller = PaneTreeNodeController(
            node: node,
            store: store,
            sessions: sessions
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
            previewURL: URL?,
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
        sessions: TerminalSessionPool
    ) {
        switch node {
        case .terminal(let pane):
            let previewURL = sessions.previewURL(for: pane.id)
            let host = NSHostingView(
                rootView: AnyView(
                    TerminalPaneView(
                        pane: pane,
                        store: store,
                        sessions: sessions
                    )
                    .id(pane.id)
                )
            )
            host.sizingOptions = []
            content = .terminal(
                pane: pane,
                previewURL: previewURL,
                host: host
            )

        case .split(let split):
            let first = PaneTreeNodeController(
                node: split.first,
                store: store,
                sessions: sessions
            )
            let second = PaneTreeNodeController(
                node: split.second,
                store: store,
                sessions: sessions
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
        sessions: TerminalSessionPool
    ) {
        switch (content, node) {
        case (
            .terminal(let previousPane, let previousPreviewURL, let host),
            .terminal(let pane)
        ):
            let previewURL = sessions.previewURL(for: pane.id)
            guard pane != previousPane || previewURL != previousPreviewURL else {
                return
            }
            host.rootView = AnyView(
                TerminalPaneView(
                    pane: pane,
                    store: store,
                    sessions: sessions
                )
                .id(pane.id)
            )
            content = .terminal(
                pane: pane,
                previewURL: previewURL,
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
            first.update(node: split.first, store: store, sessions: sessions)
            second.update(node: split.second, store: store, sessions: sessions)
            splitView.setTheme(sessions.terminalTheme)
            splitView.setRatio(split.ratio)

        default:
            return
        }
    }
}

private struct TerminalPaneView: View {
    let pane: TerminalPane
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool

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
                    .help("Return to Terminal")
                    .accessibilityLabel("Return to terminal")
                } else if case .exited = sessions.status(for: pane.id) {
                    Button {
                        sessions.restart(pane: pane)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Restart Terminal")
                    .accessibilityLabel("Restart terminal")
                }

                Button {
                    store.closePane(withID: pane.id)
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
