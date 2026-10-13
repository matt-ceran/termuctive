import AppKit
import SwiftTerm
import SwiftUI

/// A small live terminal used by cloud setup sheets for steps that need typing,
/// such as an ssh password or a sudo prompt, and whose output should stay readable.
struct EmbeddedTerminal: NSViewRepresentable {
    let executable: String
    let arguments: [String]
    var onOutput: (String) -> Void = { _ in }
    let onExit: (TerminalProcessExit) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOutput: onOutput, onExit: onExit)
    }

    func makeNSView(context: Context) -> EmbeddedTerminalView {
        let view = EmbeddedTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.outputHandler = { [weak coordinator = context.coordinator] text in
            coordinator?.receive(text)
        }
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.optionAsMetaKey = true
        view.startProcess(
            executable: executable,
            args: arguments,
            environment: TerminalShellConfiguration.live.environment,
            execName: nil,
            currentDirectory: NSHomeDirectory()
        )
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: EmbeddedTerminalView, context: Context) {
        context.coordinator.onOutput = onOutput
        context.coordinator.onExit = onExit
    }

    static func dismantleNSView(_ view: EmbeddedTerminalView, coordinator: Coordinator) {
        coordinator.onExit = { _ in }
        if view.process.running {
            view.terminate()
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onOutput: (String) -> Void
        var onExit: (TerminalProcessExit) -> Void

        init(
            onOutput: @escaping (String) -> Void,
            onExit: @escaping (TerminalProcessExit) -> Void
        ) {
            self.onOutput = onOutput
            self.onExit = onExit
        }

        func receive(_ text: String) {
            DispatchQueue.main.async { [weak self] in
                self?.onOutput(text)
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let exit = TerminalProcessExit(waitStatus: exitCode)
            DispatchQueue.main.async { [weak self] in
                self?.onExit(exit)
            }
        }
    }
}

final class EmbeddedTerminalView: LocalProcessTerminalView {
    var outputHandler: ((String) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        outputHandler?(String(decoding: slice, as: UTF8.self))
    }
}
