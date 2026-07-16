import AppKit
import Combine
import SwiftTerm

enum TerminalSessionStatus: Equatable {
    case running
    case exited(Int32?)
}

@MainActor
final class TerminalSessionPool: ObservableObject {
    @Published private var titles: [UUID: String] = [:]
    @Published private var statuses: [UUID: TerminalSessionStatus] = [:]

    private let store: WorkspaceStore
    private var sessions: [UUID: TerminalSession] = [:]

    init(store: WorkspaceStore) {
        self.store = store
    }

    func terminalView(for pane: TerminalPane) -> TermuctiveTerminalView {
        if let session = sessions[pane.id] {
            return session.view
        }

        let session = TerminalSession(
            pane: pane,
            onFocus: { [weak self] paneID in
                Task { @MainActor in
                    self?.focus(paneID: paneID)
                }
            },
            onTitleChange: { [weak self] paneID, title in
                Task { @MainActor in
                    self?.setTitle(title, for: paneID)
                }
            },
            onDirectoryChange: { [weak self] paneID, directory in
                Task { @MainActor in
                    self?.store.updateTerminal(
                        paneID: paneID,
                        workingDirectory: directory
                    )
                }
            },
            onTermination: { [weak self] paneID, exitCode in
                Task { @MainActor in
                    self?.markExited(paneID: paneID, exitCode: exitCode)
                }
            }
        )
        sessions[pane.id] = session
        titles[pane.id] = pane.title
        statuses[pane.id] = session.start() ? .running : .exited(nil)
        return session.view
    }

    func title(for pane: TerminalPane) -> String {
        titles[pane.id] ?? pane.title
    }

    func status(for paneID: UUID) -> TerminalSessionStatus {
        statuses[paneID] ?? .running
    }

    func focus(paneID: UUID) {
        store.focusPane(withID: paneID)
        guard let view = sessions[paneID]?.view else {
            return
        }
        view.requestFocus()
    }

    func restart(pane: TerminalPane) {
        guard let session = sessions[pane.id] else {
            _ = terminalView(for: pane)
            return
        }
        titles[pane.id] = pane.title
        statuses[pane.id] = session.restart(pane: pane) ? .running : .exited(nil)
        focus(paneID: pane.id)
    }

    func reconcile(validPaneIDs: Set<UUID>) {
        let removedIDs = Set(sessions.keys).subtracting(validPaneIDs)
        for id in removedIDs {
            sessions.removeValue(forKey: id)?.terminate()
            titles.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
        }
    }

    func terminateAll() {
        for session in sessions.values {
            session.terminate()
        }
        sessions.removeAll()
        titles.removeAll()
        statuses.removeAll()
    }

    private func setTitle(_ title: String, for paneID: UUID) {
        guard sessions[paneID] != nil else {
            return
        }
        titles[paneID] = title
    }

    private func markExited(paneID: UUID, exitCode: Int32?) {
        guard sessions[paneID] != nil else {
            return
        }
        statuses[paneID] = .exited(exitCode)
    }
}

final class TermuctiveTerminalView: LocalProcessTerminalView {
    var focusHandler: (() -> Void)?
    private var hasPendingFocusRequest = false

    func requestFocus() {
        hasPendingFocusRequest = true
        applyPendingFocusRequest()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocusRequest()
    }

    override func mouseDown(with event: NSEvent) {
        focusHandler?()
        super.mouseDown(with: event)
    }

    private func applyPendingFocusRequest() {
        guard hasPendingFocusRequest,
            let window,
            window.makeFirstResponder(self)
        else {
            return
        }
        hasPendingFocusRequest = false
    }
}

private final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let paneID: UUID
    let view: TermuctiveTerminalView

    private var pane: TerminalPane
    private let onTitleChange: (UUID, String) -> Void
    private let onDirectoryChange: (UUID, String) -> Void
    private let onTermination: (UUID, Int32?) -> Void

    init(
        pane: TerminalPane,
        onFocus: @escaping (UUID) -> Void,
        onTitleChange: @escaping (UUID, String) -> Void,
        onDirectoryChange: @escaping (UUID, String) -> Void,
        onTermination: @escaping (UUID, Int32?) -> Void
    ) {
        paneID = pane.id
        self.pane = pane
        self.onTitleChange = onTitleChange
        self.onDirectoryChange = onDirectoryChange
        self.onTermination = onTermination
        view = TermuctiveTerminalView(frame: .zero)
        super.init()

        view.processDelegate = self
        view.focusHandler = { [paneID] in
            onFocus(paneID)
        }
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.fontSmoothing = false
        view.lineSpacing = 1.08
        view.nativeForegroundColor = NSColor(
            calibratedRed: 0.86,
            green: 0.88,
            blue: 0.91,
            alpha: 1
        )
        view.nativeBackgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.059,
            blue: 0.067,
            alpha: 1
        )
        view.caretViewTracksFocus = true
        view.optionAsMetaKey = true
        view.allowMouseReporting = true
    }

    func start() -> Bool {
        start(pane: pane)
    }

    func restart(pane: TerminalPane) -> Bool {
        self.pane = pane
        return start(pane: pane)
    }

    func terminate() {
        if view.process.running {
            view.terminate()
        }
    }

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitleChange(paneID, title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory,
            let path = Self.path(fromTerminalDirectory: directory)
        else {
            return
        }
        pane.workingDirectory = path
        onDirectoryChange(paneID, path)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onTermination(paneID, exitCode)
    }

    private func start(pane: TerminalPane) -> Bool {
        guard !view.process.running else {
            return true
        }

        let shell = Self.shellPath
        let currentDirectory = Self.validDirectory(pane.workingDirectory)
        if currentDirectory != pane.workingDirectory {
            self.pane.workingDirectory = currentDirectory
            onDirectoryChange(paneID, currentDirectory)
        }
        view.startProcess(
            executable: shell,
            environment: Self.environment,
            execName: "-\(URL(fileURLWithPath: shell).lastPathComponent)",
            currentDirectory: currentDirectory
        )
        return view.process.running
    }

    private static var shellPath: String {
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: configured) else {
            return "/bin/zsh"
        }
        return configured
    }

    private static var environment: [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Termuctive"
        environment["TERM_PROGRAM_VERSION"] = "0.1.0"
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    private static func validDirectory(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func path(fromTerminalDirectory directory: String) -> String? {
        if let url = URL(string: directory), url.isFileURL {
            return url.path
        }
        return directory.hasPrefix("/") ? directory : nil
    }
}
