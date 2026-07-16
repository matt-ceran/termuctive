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
    let splitID: UUID
    let availableLength: CGFloat
    let onChange: (Double, Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(
                    Color(nsColor: .separatorColor)
                        .opacity(isHovered ? 0.5 : 0.28)
                )
                .frame(
                    width: axis == .horizontal ? 1 : nil,
                    height: axis == .vertical ? 1 : nil
                )
        }
        .frame(
            width: axis == .horizontal ? 5 : nil,
            height: axis == .vertical ? 5 : nil
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
            DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(splitID)
            )
            .onChanged { value in
                updateRatio(at: value.location, persist: false)
            }
            .onEnded { value in
                updateRatio(at: value.location, persist: true)
            }
        )
    }

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private func updateRatio(at point: CGPoint, persist: Bool) {
        guard availableLength > 0 else {
            return
        }
        let location = axis == .horizontal ? point.x : point.y
        onChange(location / availableLength, persist)
    }
}
