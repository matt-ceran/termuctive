import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let pane: TerminalPane
    let isFocused: Bool
    let sessions: TerminalSessionPool

    final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalViewportView {
        let terminal = sessions.terminalView(for: pane)
        let viewport = TerminalViewportView(terminal: terminal)
        context.coordinator.wasFocused = isFocused
        terminal.setWantsFocus(isFocused)
        return viewport
    }

    func updateNSView(_ viewport: TerminalViewportView, context: Context) {
        let focusChanged = isFocused != context.coordinator.wasFocused
        context.coordinator.wasFocused = isFocused
        guard focusChanged else {
            return
        }
        viewport.terminal.setWantsFocus(isFocused)
    }

    static func dismantleNSView(
        _ viewport: TerminalViewportView,
        coordinator: Coordinator
    ) {
        viewport.prepareForDetachment()
    }
}

@MainActor
final class TerminalViewportView: NSView {
    let terminal: TermuctiveTerminalView

    private var attachmentLease: TerminalResizeLease?
    private var windowResizeLease: TerminalResizeLease?
    private var lastRequestedSize = NSSize.zero
    private var lastBackgroundColor: CGColor?

    init(terminal: TermuctiveTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        attachmentLease = terminal.beginInteractivePaneResize(reason: .attachment)
        addSubview(terminal)
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard terminal.superview === self else {
            return
        }
        let requestedSize = bounds.size
        if requestedSize != lastRequestedSize {
            lastRequestedSize = requestedSize
            terminal.setFrameSize(requestedSize)
        }
        alignTerminalToTop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard terminal.superview === self else {
            return
        }
        beginAttachmentStabilization()
        guard window != nil else {
            return
        }

        let lease = attachmentLease
        DispatchQueue.main.async { [weak self] in
            guard let self,
                window != nil,
                terminal.superview === self,
                attachmentLease == lease,
                let lease
            else {
                return
            }
            layoutSubtreeIfNeeded()
            terminal.endInteractivePaneResize(lease)
            attachmentLease = nil
            alignTerminalToTop()
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        guard terminal.superview === self else {
            return
        }
        if windowResizeLease == nil {
            windowResizeLease = terminal.beginInteractivePaneResize(
                reason: .windowLiveResize
            )
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        endWindowResizeLease()
        guard terminal.superview === self else {
            return
        }
        alignTerminalToTop()
    }

    func prepareForDetachment() {
        endWindowResizeLease()
        guard terminal.superview === self else {
            return
        }
        beginAttachmentStabilization()
        terminal.setWantsFocus(false)
    }

    func updateBackgroundColor() {
        let backgroundColor = terminal.nativeBackgroundColor.cgColor
        guard lastBackgroundColor != backgroundColor else {
            return
        }
        lastBackgroundColor = backgroundColor
        layer?.backgroundColor = backgroundColor
    }

    func terminalFrameDidCommit() {
        guard terminal.superview === self else {
            return
        }
        alignTerminalToTop()
    }

    private func alignTerminalToTop() {
        let origin = NSPoint(
            x: bounds.minX,
            y: bounds.maxY - terminal.frame.height
        )
        guard terminal.frame.origin != origin else {
            return
        }
        terminal.setFrameOrigin(origin)
    }

    private func beginAttachmentStabilization() {
        attachmentLease = terminal.beginInteractivePaneResize(reason: .attachment)
    }

    private func endWindowResizeLease() {
        guard let windowResizeLease else {
            return
        }
        terminal.endInteractivePaneResize(windowResizeLease)
        self.windowResizeLease = nil
    }
}
