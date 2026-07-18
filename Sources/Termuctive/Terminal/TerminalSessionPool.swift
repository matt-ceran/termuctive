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
    @Published private(set) var fontSize: CGFloat = 11
    @Published private(set) var terminalTheme: TerminalTheme
    @Published private var pdfPreviewURLs: [UUID: URL] = [:]
    @Published private var pdfSearchPaneIDs: Set<UUID> = []

    private let store: WorkspaceStore
    private var sessions: [UUID: TerminalSession] = [:]
    private var recentPDFURLs: [UUID: [URL]] = [:]
    private var layoutTransitionGeneration = 0

    init(store: WorkspaceStore, terminalTheme: TerminalTheme = .light) {
        self.store = store
        self.terminalTheme = terminalTheme
    }

    func terminalView(for pane: TerminalPane) -> TermuctiveTerminalView {
        if let session = sessions[pane.id] {
            return session.view
        }

        let session = TerminalSession(
            pane: pane,
            fontSize: fontSize,
            theme: terminalTheme,
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
            onLocalCommand: { [weak self] paneID, command in
                Task { @MainActor in
                    self?.perform(command, fromPaneID: paneID)
                }
            },
            onPDFPathDetected: { [weak self] paneID, url in
                Task { @MainActor in
                    self?.rememberPDF(url, forPaneID: paneID)
                }
            },
            onTermination: { [weak self] paneID, exitCode in
                Task { @MainActor in
                    self?.markExited(paneID: paneID, exitCode: exitCode)
                }
            }
        )
        sessions[pane.id] = session
        if !session.start() {
            Task { @MainActor [weak self] in
                self?.markExited(paneID: pane.id, exitCode: nil)
            }
        }
        return session.view
    }

    func title(for pane: TerminalPane) -> String {
        titles[pane.id] ?? pane.title
    }

    func status(for paneID: UUID) -> TerminalSessionStatus {
        statuses[paneID] ?? .running
    }

    func previewURL(for paneID: UUID) -> URL? {
        pdfPreviewURLs[paneID]
    }

    func isFindingPDF(for paneID: UUID) -> Bool {
        pdfSearchPaneIDs.contains(paneID)
    }

    func dismissPDFPreview(inPaneID paneID: UUID) {
        pdfPreviewURLs.removeValue(forKey: paneID)
        focus(paneID: paneID)
    }

    func moveRecentPDF(fromPaneID paneID: UUID, placement: PDFPanePlacement) {
        guard !pdfSearchPaneIDs.contains(paneID) else {
            return
        }

        if let detectedPDF = recentPDFURLs[paneID]?.last(where: Self.fileExists) {
            presentPDF(detectedPDF, fromPaneID: paneID, placement: placement)
            return
        }

        let roots = store.pdfSearchRoots(forPaneID: paneID)
        guard !roots.isEmpty,
            let sessionStart = sessions[paneID]?.startedAt
        else {
            store.presentError("Termuctive could not identify this terminal's project directory.")
            return
        }

        pdfSearchPaneIDs.insert(paneID)
        Task { [weak self] in
            let pdf = await Task.detached(priority: .userInitiated) {
                RecentPDFLocator.mostRecentPDF(
                    in: roots,
                    modifiedAfter: sessionStart.addingTimeInterval(-1)
                )
            }.value
            guard let self else {
                return
            }
            pdfSearchPaneIDs.remove(paneID)
            guard let pdf else {
                store.presentError(
                    "No PDF created during this terminal session was found in the project."
                )
                return
            }
            rememberPDF(pdf, forPaneID: paneID)
            presentPDF(pdf, fromPaneID: paneID, placement: placement)
        }
    }

    var canIncreaseFontSize: Bool {
        fontSize < Self.fontSizeRange.upperBound
    }

    var canDecreaseFontSize: Bool {
        fontSize > Self.fontSizeRange.lowerBound
    }

    func increaseFontSize() {
        setFontSize(fontSize + 1)
    }

    func decreaseFontSize() {
        setFontSize(fontSize - 1)
    }

    func setTerminalTheme(_ theme: TerminalTheme) {
        guard terminalTheme != theme else {
            return
        }
        terminalTheme = theme
        for session in sessions.values {
            session.setTheme(theme)
        }
    }

    func prepareForAnimatedLayoutTransition(duration: TimeInterval) {
        layoutTransitionGeneration &+= 1
        let generation = layoutTransitionGeneration
        for session in sessions.values {
            session.view.beginInteractivePaneResize(reason: .animatedLayout)
        }

        Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(duration + 0.04, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self,
                layoutTransitionGeneration == generation
            else {
                return
            }
            for session in sessions.values {
                session.view.endInteractivePaneResize(reason: .animatedLayout)
            }
        }
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
            pdfPreviewURLs.removeValue(forKey: id)
            pdfSearchPaneIDs.remove(id)
            recentPDFURLs.removeValue(forKey: id)
        }
    }

    func terminateAll() {
        layoutTransitionGeneration &+= 1
        for session in sessions.values {
            session.view.cancelInteractivePaneResizes()
            session.terminate()
        }
        sessions.removeAll()
        titles.removeAll()
        statuses.removeAll()
        pdfPreviewURLs.removeAll()
        pdfSearchPaneIDs.removeAll()
        recentPDFURLs.removeAll()
    }

    private func perform(_ command: TerminalLocalCommand, fromPaneID paneID: UUID) {
        switch command {
        case .moveRecentPDF(let placement):
            moveRecentPDF(fromPaneID: paneID, placement: placement)
        }
    }

    private func presentPDF(
        _ url: URL,
        fromPaneID paneID: UUID,
        placement: PDFPanePlacement
    ) {
        guard Self.fileExists(url),
            let targetPaneID = store.preparePDFPane(
                fromPaneID: paneID,
                placement: placement
            )
        else {
            store.presentError("Termuctive could not open the PDF in the requested pane.")
            return
        }
        pdfPreviewURLs[targetPaneID] = url.standardizedFileURL
    }

    private func rememberPDF(_ url: URL, forPaneID paneID: UUID) {
        let standardizedURL = url.standardizedFileURL
        guard Self.fileExists(standardizedURL) else {
            return
        }
        var urls = recentPDFURLs[paneID, default: []]
        urls.removeAll { $0 == standardizedURL }
        urls.append(standardizedURL)
        recentPDFURLs[paneID] = Array(urls.suffix(20))
    }

    private static func fileExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
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

    private func setFontSize(_ proposedSize: CGFloat) {
        let size = min(
            max(proposedSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        guard size != fontSize else {
            return
        }
        fontSize = size
        for session in sessions.values {
            session.setFontSize(size)
        }
    }

    private static let fontSizeRange: ClosedRange<CGFloat> = 8...32
}

enum TerminalResizeReason: Hashable {
    case animatedLayout
    case attachment
    case divider
    case windowLiveResize
}

final class TermuctiveTerminalView: LocalProcessTerminalView {
    var focusHandler: (() -> Void)?
    var localCommandHandler: ((TerminalLocalCommand) -> Void)?
    var outputHandler: ((ArraySlice<UInt8>) -> Void)?

    private var localCommandTracker = TerminalLocalCommandTracker()
    private var isForwardingTrackedText = false
    private var suppressEnhancedSubmitRelease = false
    private var hasPendingFocusRequest = false
    private var hasAttemptedAcceleratedRendering = false
    private var activeResizeReasons: Set<TerminalResizeReason> = []
    private var pendingFrameSize: NSSize?
    private var isFrameCoordinationReady = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isFrameCoordinationReady = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isFrameCoordinationReady = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard isFrameCoordinationReady else {
            super.setFrameSize(newSize)
            return
        }
        guard isUsableFrameSize(newSize) else {
            return
        }
        guard activeResizeReasons.isEmpty else {
            // The viewport clips the stable grid until the final size is committed.
            pendingFrameSize = newSize
            return
        }
        pendingFrameSize = nil
        super.setFrameSize(newSize)
    }

    func requestFocus() {
        hasPendingFocusRequest = true
        applyPendingFocusRequest()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enableAcceleratedRenderingIfAvailable()
        applyPendingFocusRequest()
    }

    override func mouseDown(with event: NSEvent) {
        focusHandler?()
        super.mouseDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = Self.plainText(from: string) {
            localCommandTracker.insert(text)
        } else {
            localCommandTracker.invalidate()
        }
        isForwardingTrackedText = true
        defer { isForwardingTrackedText = false }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any) {
        if let text = NSPasteboard.general.string(forType: .string) {
            localCommandTracker.insert(text)
        } else {
            localCommandTracker.invalidate()
        }
        isForwardingTrackedText = true
        defer { isForwardingTrackedText = false }
        super.paste(sender)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !isForwardingTrackedText else {
            super.send(source: source, data: data)
            return
        }

        switch TerminalControlInput(bytes: data) {
        case .submit(let enhanced):
            if let command = localCommandTracker.commandForSubmission() {
                suppressEnhancedSubmitRelease = enhanced
                clearApplicationInput()
                localCommandHandler?(command)
                return
            }
            suppressEnhancedSubmitRelease = false
        case .backspace:
            localCommandTracker.deleteBackward()
        case .resetLine:
            localCommandTracker.reset()
        case .invalidateLine:
            localCommandTracker.invalidate()
        case .enhancedRelease(let keyCode):
            if keyCode == 13, suppressEnhancedSubmitRelease {
                suppressEnhancedSubmitRelease = false
                return
            }
        case .other:
            break
        }
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        outputHandler?(slice)
        super.dataReceived(slice: slice)
    }

    func applyTheme(_ theme: TerminalTheme, redraw: Bool) {
        let shouldRebuildMetalRenderer = redraw && isUsingMetalRenderer && window != nil
        if shouldRebuildMetalRenderer {
            try? setUseMetal(false)
        }

        nativeForegroundColor = theme.foregroundColor
        nativeBackgroundColor = theme.backgroundColor
        caretColor = theme.foregroundColor
        caretTextColor = theme.backgroundColor
        selectedTextBackgroundColor = theme.selectionColor
        layer?.backgroundColor = theme.backgroundColor.cgColor
        (superview as? TerminalViewportView)?.updateBackgroundColor()
        getTerminal().updateFullScreen()
        needsDisplay = true

        if shouldRebuildMetalRenderer {
            try? setUseMetal(true)
        }
    }

    private func clearApplicationInput() {
        let bytes: [UInt8]
        let flags = getTerminal().keyboardEnhancementFlags
        if flags.contains(.disambiguate) || flags.contains(.reportAllKeys) {
            // Ctrl+U encoded with the Kitty keyboard protocol.
            bytes = Array("\u{1B}[117;5u".utf8)
        } else {
            bytes = [0x15]
        }
        super.send(source: self, data: bytes[...])
    }

    private static func plainText(from value: Any) -> String? {
        if let text = value as? String {
            return text
        }
        if let attributedText = value as? NSAttributedString {
            return attributedText.string
        }
        return nil
    }

    func beginInteractivePaneResize(reason: TerminalResizeReason = .divider) {
        activeResizeReasons.insert(reason)
    }

    func endInteractivePaneResize(reason: TerminalResizeReason = .divider) {
        activeResizeReasons.remove(reason)
        guard activeResizeReasons.isEmpty,
            let pendingFrameSize
        else {
            return
        }
        self.pendingFrameSize = nil
        super.setFrameSize(pendingFrameSize)
    }

    func cancelInteractivePaneResizes() {
        activeResizeReasons.removeAll()
        pendingFrameSize = nil
    }

    private func isUsableFrameSize(_ size: NSSize) -> Bool {
        guard size.width.isFinite,
            size.height.isFinite,
            size.width > 0,
            size.height > 0
        else {
            return false
        }

        // Ignore zero and sub-cell teardown frames instead of shrinking the PTY to its minimum.
        let terminal = getTerminal()
        let optimalSize = getOptimalFrameSize().size
        let cellWidth = optimalSize.width / CGFloat(max(terminal.cols, 1))
        let cellHeight = optimalSize.height / CGFloat(max(terminal.rows, 1))
        return size.width >= max(cellWidth, 1)
            && size.height >= max(cellHeight, 1)
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

    private func enableAcceleratedRenderingIfAvailable() {
        guard window != nil,
            !hasAttemptedAcceleratedRendering
        else {
            return
        }
        hasAttemptedAcceleratedRendering = true
        try? setUseMetal(true)
    }
}

private final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let paneID: UUID
    let view: TermuctiveTerminalView
    private(set) var startedAt = Date()

    private var pane: TerminalPane
    private var outputPDFTracker = TerminalOutputPDFTracker()
    private let onTitleChange: (UUID, String) -> Void
    private let onDirectoryChange: (UUID, String) -> Void
    private let onLocalCommand: (UUID, TerminalLocalCommand) -> Void
    private let onPDFPathDetected: (UUID, URL) -> Void
    private let onTermination: (UUID, Int32?) -> Void

    init(
        pane: TerminalPane,
        fontSize: CGFloat,
        theme: TerminalTheme,
        onFocus: @escaping (UUID) -> Void,
        onTitleChange: @escaping (UUID, String) -> Void,
        onDirectoryChange: @escaping (UUID, String) -> Void,
        onLocalCommand: @escaping (UUID, TerminalLocalCommand) -> Void,
        onPDFPathDetected: @escaping (UUID, URL) -> Void,
        onTermination: @escaping (UUID, Int32?) -> Void
    ) {
        paneID = pane.id
        self.pane = pane
        self.onTitleChange = onTitleChange
        self.onDirectoryChange = onDirectoryChange
        self.onLocalCommand = onLocalCommand
        self.onPDFPathDetected = onPDFPathDetected
        self.onTermination = onTermination
        view = TermuctiveTerminalView(frame: .zero)
        super.init()

        view.processDelegate = self
        view.focusHandler = { [paneID] in
            onFocus(paneID)
        }
        view.localCommandHandler = { [weak self] command in
            guard let self else {
                return
            }
            self.onLocalCommand(self.paneID, command)
        }
        view.outputHandler = { [weak self] bytes in
            self?.trackPDFs(in: bytes)
        }
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.fontSmoothing = true
        view.lineSpacing = 1.08
        view.applyTheme(theme, redraw: false)
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

    func setFontSize(_ size: CGFloat) {
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func setTheme(_ theme: TerminalTheme) {
        view.applyTheme(theme, redraw: true)
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

        startedAt = Date()
        outputPDFTracker = TerminalOutputPDFTracker()
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

    private func trackPDFs(in bytes: ArraySlice<UInt8>) {
        let urls = outputPDFTracker.consume(
            bytes,
            workingDirectory: pane.workingDirectory
        )
        for url in urls {
            onPDFPathDetected(paneID, url)
        }
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
