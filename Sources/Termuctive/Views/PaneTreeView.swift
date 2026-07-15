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
                sessions: sessions
            )
            .id(pane.id)

        case .split(let split):
            GeometryReader { proxy in
                let available =
                    split.axis == .horizontal
                    ? proxy.size.width
                    : proxy.size.height
                let firstLength = max(0, available - 5) * split.ratio

                Group {
                    if split.axis == .horizontal {
                        HStack(spacing: 0) {
                            PaneTreeView(node: split.first, store: store, sessions: sessions)
                                .frame(width: firstLength)
                            divider(for: split, available: available)
                            PaneTreeView(node: split.second, store: store, sessions: sessions)
                        }
                    } else {
                        VStack(spacing: 0) {
                            PaneTreeView(node: split.first, store: store, sessions: sessions)
                                .frame(height: firstLength)
                            divider(for: split, available: available)
                            PaneTreeView(node: split.second, store: store, sessions: sessions)
                        }
                    }
                }
                .coordinateSpace(name: split.id)
            }
        }
    }

    private func divider(for split: PaneSplit, available: CGFloat) -> some View {
        SplitDivider(
            axis: split.axis,
            splitID: split.id,
            availableLength: available,
            onChange: { ratio, persist in
                store.setSplitRatio(
                    splitID: split.id,
                    ratio: ratio,
                    persist: persist
                )
            }
        )
    }
}

private struct TerminalPaneView: View {
    let pane: TerminalPane
    let isFocused: Bool
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
        .overlay {
            Rectangle()
                .stroke(
                    isFocused ? Color.accentColor : Color.clear,
                    lineWidth: 1
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
