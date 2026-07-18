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
        if isFocused {
            terminal.requestFocus()
        }
        return viewport
    }

    func updateNSView(_ viewport: TerminalViewportView, context: Context) {
        let shouldFocus = isFocused && !context.coordinator.wasFocused
        context.coordinator.wasFocused = isFocused
        guard shouldFocus else {
            return
        }
        viewport.terminal.requestFocus()
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

    init(terminal: TermuctiveTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        // Keep the terminal grid fixed while this viewport is attached and laid out.
        terminal.beginInteractivePaneResize(reason: .attachment)
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
        terminal.setFrameSize(bounds.size)
        alignTerminalToTop()
        updateBackgroundColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard terminal.superview === self else {
            return
        }
        terminal.beginInteractivePaneResize(reason: .attachment)
        guard window != nil else {
            return
        }

        // SwiftUI can apply more than one intermediate frame while reattaching a pooled view.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                    window != nil,
                    terminal.superview === self
                else {
                    return
                }
                layoutSubtreeIfNeeded()
                terminal.endInteractivePaneResize(reason: .attachment)
                alignTerminalToTop()
            }
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        guard terminal.superview === self else {
            return
        }
        terminal.beginInteractivePaneResize(reason: .windowLiveResize)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard terminal.superview === self else {
            return
        }
        terminal.endInteractivePaneResize(reason: .windowLiveResize)
        alignTerminalToTop()
    }

    func prepareForDetachment() {
        guard terminal.superview === self else {
            return
        }
        terminal.beginInteractivePaneResize(reason: .attachment)
    }

    func updateBackgroundColor() {
        layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
    }

    private func alignTerminalToTop() {
        terminal.setFrameOrigin(
            NSPoint(
                x: bounds.minX,
                y: bounds.maxY - terminal.frame.height
            )
        )
    }
}
