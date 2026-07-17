import AppKit
import SwiftUI

struct SquareIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.12)
                    : Color.clear
            )
    }
}

struct SplitDivider: View {
    let axis: PaneAxis
    let onDrag: (CGFloat, Bool) -> Void

    static let hitThickness: CGFloat = 5

    @State private var isHovered = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Color(nsColor: TerminalAppearance.backgroundColor)
            Rectangle()
                .fill(
                    Color(white: 0.72)
                        .opacity(isHovered ? 0.32 : 0.18)
                )
                .frame(
                    width: axis == .horizontal ? hairlineThickness : nil,
                    height: axis == .vertical ? hairlineThickness : nil
                )
        }
        .frame(
            width: axis == .horizontal ? Self.hitThickness : nil,
            height: axis == .vertical ? Self.hitThickness : nil
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                resizeCursor.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onDrag(translation(for: value), false)
                }
                .onEnded { value in
                    onDrag(translation(for: value), true)
                }
        )
    }

    private var hairlineThickness: CGFloat {
        1 / max(displayScale, 1)
    }

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private func translation(for value: DragGesture.Value) -> CGFloat {
        axis == .horizontal ? value.translation.width : value.translation.height
    }
}
