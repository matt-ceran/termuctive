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
        case .terminal(_, let host):
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
            content = .terminal(pane: pane, host: host)

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
        case (.terminal(let pane, _), .terminal(let updatedPane)):
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
        case (.terminal(let previousPane, let host), .terminal(let pane)):
            guard pane != previousPane else {
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
            content = .terminal(pane: pane, host: host)

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
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
                Text(sessions.title(for: pane))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(abbreviatedPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

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

                Button {
                    store.closePane(withID: pane.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Terminal")
                .accessibilityLabel("Close terminal")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture {
                sessions.focus(paneID: pane.id)
            }

            TerminalHostView(
                pane: pane,
                isFocused: store.focusedPaneID == pane.id,
                sessions: sessions
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(sessions.title(for: pane)) terminal")
    }

    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard pane.workingDirectory.hasPrefix(home) else {
            return pane.workingDirectory
        }
        return "~" + pane.workingDirectory.dropFirst(home.count)
    }
}
