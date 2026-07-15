import SwiftUI

struct PaneTreeView: View {
    let node: PaneNode
    @ObservedObject var store: WorkspaceStore

    @ViewBuilder
    var body: some View {
        switch node {
        case .terminal(let pane):
            TerminalPlaceholderView(
                pane: pane,
                isFocused: store.focusedPaneID == pane.id,
                onFocus: { store.focusPane(withID: pane.id) }
            )

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
                            PaneTreeView(node: split.first, store: store)
                                .frame(width: firstLength)
                            divider(for: split, available: available)
                            PaneTreeView(node: split.second, store: store)
                        }
                    } else {
                        VStack(spacing: 0) {
                            PaneTreeView(node: split.first, store: store)
                                .frame(height: firstLength)
                            divider(for: split, available: available)
                            PaneTreeView(node: split.second, store: store)
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

private struct TerminalPlaceholderView: View {
    let pane: TerminalPane
    let isFocused: Bool
    let onFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
                Text(pane.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(abbreviatedPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor))

            Color(red: 0.055, green: 0.059, blue: 0.067)
        }
        .overlay {
            Rectangle()
                .stroke(
                    isFocused ? Color.accentColor : Color.clear,
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pane.title) terminal")
    }

    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard pane.workingDirectory.hasPrefix(home) else {
            return pane.workingDirectory
        }
        return "~" + pane.workingDirectory.dropFirst(home.count)
    }
}
