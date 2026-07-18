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

@MainActor
final class SmoothSplitView: NSSplitView, NSSplitViewDelegate {
    static let hitThickness: CGFloat = 5

    var onRatioCommit: ((Double) -> Void)?

    private var desiredRatio = 0.5
    private var terminalTheme: TerminalTheme = .light
    private var isTrackingDivider = false
    private var isApplyingRatio = false
    private var needsRatioApplication = true
    private var lastLayoutSize = NSSize.zero
    private var dividerTrackingArea: NSTrackingArea?
    private var isDividerHovered = false

    init(axis: PaneAxis) {
        super.init(frame: .zero)
        isVertical = axis == .horizontal
        dividerStyle = .thin
        delegate = self
        wantsLayer = true
        setAccessibilityRole(.splitGroup)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
        wantsLayer = true
        setAccessibilityRole(.splitGroup)
    }

    override var dividerThickness: CGFloat {
        Self.hitThickness
    }

    var ratio: Double {
        guard arrangedSubviews.count == 2 else {
            return desiredRatio
        }
        let availableLength = max(0, primaryLength - dividerThickness)
        guard availableLength > 0 else {
            return desiredRatio
        }
        let firstLength =
            isVertical
            ? arrangedSubviews[0].frame.width
            : arrangedSubviews[0].frame.height
        return min(max(Double(firstLength / availableLength), 0.1), 0.9)
    }

    func setRatio(_ ratio: Double) {
        desiredRatio = min(max(ratio, 0.1), 0.9)
        guard !isTrackingDivider else {
            return
        }
        needsRatioApplication = true
        needsLayout = true
    }

    func setTheme(_ theme: TerminalTheme) {
        guard terminalTheme != theme else {
            return
        }
        terminalTheme = theme
        layer?.backgroundColor = theme.backgroundColor.cgColor
        needsDisplay = true
    }

    override func layout() {
        let sizeChanged = bounds.size != lastLayoutSize
        super.layout()
        if !isTrackingDivider,
            needsRatioApplication || sizeChanged
        {
            applyDesiredRatio()
        }
        lastLayoutSize = bounds.size
        window?.invalidateCursorRects(for: self)
    }

    override func drawDivider(in rect: NSRect) {
        terminalTheme.backgroundColor.setFill()
        rect.fill()

        let scale = max(window?.backingScaleFactor ?? 1, 1)
        let hairline = 1 / scale
        let lineColor =
            isDividerHovered
            ? terminalTheme.foregroundColor.withAlphaComponent(0.28)
            : terminalTheme.dividerColor
        lineColor.setFill()

        if isVertical {
            let x = (rect.midX - hairline / 2) * scale
            NSRect(
                x: x.rounded() / scale,
                y: rect.minY,
                width: hairline,
                height: rect.height
            ).fill()
        } else {
            let y = (rect.midY - hairline / 2) * scale
            NSRect(
                x: rect.minX,
                y: y.rounded() / scale,
                width: rect.width,
                height: hairline
            ).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard arrangedSubviews.count == 2,
            currentDividerRect.contains(location)
        else {
            super.mouseDown(with: event)
            return
        }

        isTrackingDivider = true
        setTerminalResizeMode(active: true)
        super.mouseDown(with: event)
        desiredRatio = ratio
        isTrackingDivider = false
        needsRatioApplication = false
        setTerminalResizeMode(active: false)
        onRatioCommit?(desiredRatio)
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard arrangedSubviews.count == 2 else {
            return
        }
        addCursorRect(
            currentDividerRect,
            cursor: isVertical ? .resizeLeftRight : .resizeUpDown
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let dividerTrackingArea {
            removeTrackingArea(dividerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        dividerTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let hovered =
            arrangedSubviews.count == 2
            && currentDividerRect.contains(location)
        guard hovered != isDividerHovered else {
            return
        }
        isDividerHovered = hovered
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard isDividerHovered else {
            return
        }
        isDividerHovered = false
        needsDisplay = true
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let availableLength = max(0, primaryLength - dividerThickness)
        return min(
            max(proposedPosition, availableLength * 0.1),
            availableLength * 0.9
        )
    }

    private var primaryLength: CGFloat {
        isVertical ? bounds.width : bounds.height
    }

    private var currentDividerRect: NSRect {
        guard arrangedSubviews.count == 2 else {
            return .zero
        }
        let firstFrame = arrangedSubviews[0].frame
        let secondFrame = arrangedSubviews[1].frame
        if isVertical {
            let minimumX = min(firstFrame.maxX, secondFrame.maxX)
            let maximumX = max(firstFrame.minX, secondFrame.minX)
            return NSRect(
                x: minimumX,
                y: bounds.minY,
                width: max(maximumX - minimumX, dividerThickness),
                height: bounds.height
            )
        }

        let minimumY = min(firstFrame.maxY, secondFrame.maxY)
        let maximumY = max(firstFrame.minY, secondFrame.minY)
        return NSRect(
            x: bounds.minX,
            y: minimumY,
            width: bounds.width,
            height: max(maximumY - minimumY, dividerThickness)
        )
    }

    private func applyDesiredRatio() {
        guard arrangedSubviews.count == 2,
            !isApplyingRatio
        else {
            return
        }
        let availableLength = max(0, primaryLength - dividerThickness)
        guard availableLength > 0 else {
            return
        }
        isApplyingRatio = true
        setPosition(
            availableLength * CGFloat(desiredRatio),
            ofDividerAt: 0
        )
        isApplyingRatio = false
        needsRatioApplication = false
    }

    private func setTerminalResizeMode(active: Bool) {
        for terminal in descendantTerminalViews(in: self) {
            if active {
                terminal.beginInteractivePaneResize(reason: .divider)
            } else {
                terminal.endInteractivePaneResize(reason: .divider)
            }
        }
    }

    private func descendantTerminalViews(in view: NSView) -> [TermuctiveTerminalView] {
        view.subviews.flatMap { subview in
            if let terminal = subview as? TermuctiveTerminalView {
                return [terminal]
            }
            return descendantTerminalViews(in: subview)
        }
    }
}
