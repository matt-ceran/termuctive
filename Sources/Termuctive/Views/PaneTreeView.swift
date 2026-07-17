import SwiftUI

struct PaneTreeView: View {
    let node: PaneNode
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool

    @ViewBuilder
    var body: some View {
        switch node {
        case .terminal(let pane):
            TerminalPaneView(
                pane: pane,
                isFocused: store.focusedPaneID == pane.id,
                store: store,
                sessions: sessions
            )
            .id(pane.id)

        case .split(let split):
            SplitPaneView(split: split, store: store, sessions: sessions)
                .id(split.id)
        }
    }
}

private struct SplitPaneView: View {
    let split: PaneSplit
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool

    @State private var ratio: Double
    @State private var dragOriginRatio: Double?

    init(
        split: PaneSplit,
        store: WorkspaceStore,
        sessions: TerminalSessionPool
    ) {
        self.split = split
        self.store = store
        self.sessions = sessions
        _ratio = State(initialValue: split.ratio)
    }

    var body: some View {
        GeometryReader { proxy in
            let available =
                split.axis == .horizontal
                ? proxy.size.width
                : proxy.size.height
            let paneLength = max(0, available - SplitDivider.hitThickness)
            let firstLength = paneLength * ratio

            Group {
                if split.axis == .horizontal {
                    HStack(spacing: 0) {
                        PaneTreeView(node: split.first, store: store, sessions: sessions)
                            .frame(width: firstLength)
                        divider(availableLength: paneLength)
                        PaneTreeView(node: split.second, store: store, sessions: sessions)
                    }
                } else {
                    VStack(spacing: 0) {
                        PaneTreeView(node: split.first, store: store, sessions: sessions)
                            .frame(height: firstLength)
                        divider(availableLength: paneLength)
                        PaneTreeView(node: split.second, store: store, sessions: sessions)
                    }
                }
            }
        }
        .onChange(of: split.ratio) { _, savedRatio in
            guard dragOriginRatio == nil else {
                return
            }
            ratio = savedRatio
        }
    }

    private func divider(availableLength: CGFloat) -> some View {
        SplitDivider(
            axis: split.axis,
            onDrag: { translation, ended in
                resize(
                    translation: translation,
                    availableLength: availableLength,
                    ended: ended
                )
            }
        )
    }

    private func resize(
        translation: CGFloat,
        availableLength: CGFloat,
        ended: Bool
    ) {
        guard availableLength > 0 else {
            return
        }
        let origin = dragOriginRatio ?? ratio
        if dragOriginRatio == nil {
            dragOriginRatio = origin
        }
        let proposedRatio = origin + Double(translation / availableLength)
        let resizedRatio = min(max(proposedRatio, 0.1), 0.9)
        ratio = resizedRatio

        guard ended else {
            return
        }
        dragOriginRatio = nil
        guard resizedRatio != split.ratio else {
            return
        }
        store.commitSplitRatio(splitID: split.id, ratio: resizedRatio)
    }
}

private struct TerminalPaneView: View {
    let pane: TerminalPane
    let isFocused: Bool
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
                isFocused: isFocused,
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
