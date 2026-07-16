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

    func makeNSView(context: Context) -> TermuctiveTerminalView {
        let view = sessions.terminalView(for: pane)
        context.coordinator.wasFocused = isFocused
        if isFocused {
            view.requestFocus()
        }
        return view
    }

    func updateNSView(_ view: TermuctiveTerminalView, context: Context) {
        let shouldFocus = isFocused && !context.coordinator.wasFocused
        context.coordinator.wasFocused = isFocused
        guard shouldFocus else {
            return
        }
        view.requestFocus()
    }
}
