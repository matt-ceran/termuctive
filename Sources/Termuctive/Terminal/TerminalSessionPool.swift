import AppKit
import Combine
import QuartzCore
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

    let agentActivityRegistry: AgentActivityRegistry

    private let store: WorkspaceStore
    private let shellConfiguration: TerminalShellConfiguration
    private let agentProcessInspector: any AgentProcessInspecting
    private let agentActivityMonitor: TerminalAgentActivityMonitor
    private var agentActivityCommandTail: Task<Void, Never>?
    private var sessions: [UUID: TerminalSession] = [:]
    private var recentPDFURLs: [UUID: [URL]] = [:]
    private var animatedLayoutTransition: AnimatedLayoutTransition?

    init(
        store: WorkspaceStore,
        terminalTheme: TerminalTheme = .light,
        shellConfiguration: TerminalShellConfiguration = .live,
        agentActivityRegistry: AgentActivityRegistry? = nil,
        agentProcessInspector: any AgentProcessInspecting = MacAgentProcessInspector()
    ) {
        let activityRegistry = agentActivityRegistry ?? AgentActivityRegistry()
        self.store = store
        self.terminalTheme = terminalTheme
        self.shellConfiguration = shellConfiguration
        self.agentProcessInspector = agentProcessInspector
        self.agentActivityRegistry = activityRegistry
        agentActivityMonitor = TerminalAgentActivityMonitor(
            inspector: agentProcessInspector
        ) { [weak activityRegistry] paneID, sessionID, activity in
            activityRegistry?.setActivity(
                activity,
                paneID: paneID,
                sessionID: sessionID
            )
        }
    }

    func terminalView(for pane: TerminalPane) -> TermuctiveTerminalView {
        if let session = sessions[pane.id] {
            return session.view
        }

        let session = TerminalSession(
            pane: pane,
            fontSize: fontSize,
            theme: terminalTheme,
            shellConfiguration: shellConfiguration,
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
            captureAgentShellIdentity: { [agentProcessInspector] shellPID in
                agentProcessInspector.shellIdentity(shellPID: shellPID)
            },
            onAgentActivityStarted: {
                [weak self] paneID, shellPID, shellIdentity, sessionID in
                Task { @MainActor in
                    self?.startAgentActivity(
                        paneID: paneID,
                        shellPID: shellPID,
                        shellIdentity: shellIdentity,
                        sessionID: sessionID
                    )
                }
            },
            onAgentActivitySubmission: { [weak self] paneID, sessionID in
                Task { @MainActor in
                    self?.recordAgentActivitySubmission(
                        paneID: paneID,
                        sessionID: sessionID
                    )
                }
            },
            onAgentActivityOutput: { [weak self] paneID, sessionID in
                Task { @MainActor in
                    self?.recordAgentActivityOutput(
                        paneID: paneID,
                        sessionID: sessionID
                    )
                }
            },
            onAgentActivityStopped: { [weak self] paneID, sessionID in
                Task { @MainActor in
                    self?.stopAgentActivity(paneID: paneID, sessionID: sessionID)
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

        if let visiblePDF = sessions[paneID]?.mostRecentVisiblePDF() {
            rememberPDF(visiblePDF, forPaneID: paneID)
            presentPDF(visiblePDF, fromPaneID: paneID, placement: placement)
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

    func beginAnimatedLayoutTransition() -> UUID {
        let id = UUID()
        var leases = animatedLayoutTransition?.leases ?? [:]
        for (paneID, session) in sessions
        where session.view.window != nil
            && session.view.superview != nil
            && leases[paneID] == nil
        {
            leases[paneID] = AnimatedLayoutLease(
                terminal: session.view,
                lease: session.view.beginInteractivePaneResize(reason: .animatedLayout)
            )
        }
        animatedLayoutTransition = AnimatedLayoutTransition(id: id, leases: leases)
        return id
    }

    func finishAnimatedLayoutTransition(_ id: UUID?) {
        guard let id,
            let transition = animatedLayoutTransition,
            transition.id == id
        else {
            return
        }
        animatedLayoutTransition = nil
        for ownership in transition.leases.values {
            ownership.terminal.endInteractivePaneResize(ownership.lease)
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
        if var transition = animatedLayoutTransition {
            for id in removedIDs {
                guard let ownership = transition.leases.removeValue(forKey: id) else {
                    continue
                }
                ownership.terminal.endInteractivePaneResize(ownership.lease)
            }
            animatedLayoutTransition = transition.leases.isEmpty ? nil : transition
        }
        for id in removedIDs {
            guard let session = sessions.removeValue(forKey: id) else {
                continue
            }
            session.view.cancelInteractivePaneResizes()
            session.terminate()
            titles.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
            pdfPreviewURLs.removeValue(forKey: id)
            pdfSearchPaneIDs.remove(id)
            recentPDFURLs.removeValue(forKey: id)
        }
    }

    func terminateAll() {
        finishAnimatedLayoutTransition(animatedLayoutTransition?.id)
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
        agentActivityRegistry.clearAllSessions()
        enqueueAgentActivityCommand { monitor in
            await monitor.stopAll()
        }
    }

    private func perform(_ command: TerminalLocalCommand, fromPaneID paneID: UUID) {
        switch command {
        case .makeLearningPDF:
            guard let session = sessions[paneID] else {
                return
            }
            guard let skillURL = LearningPDFRequest.bundledSkillURL else {
                store.presentError(
                    "This Termuctive build is missing its learning PDF template."
                )
                return
            }
            session.submitApplicationLine(
                LearningPDFRequest.prompt(skillURL: skillURL)
            )
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

    private func startAgentActivity(
        paneID: UUID,
        shellPID: Int32,
        shellIdentity: AgentShellIdentity,
        sessionID: UUID
    ) {
        guard sessions[paneID]?.activitySessionID == sessionID else {
            return
        }
        agentActivityRegistry.beginSession(paneID: paneID, sessionID: sessionID)
        enqueueAgentActivityCommand { monitor in
            await monitor.register(
                paneID: paneID,
                shellPID: shellPID,
                shellIdentity: shellIdentity,
                sessionID: sessionID
            )
        }
    }

    private func recordAgentActivitySubmission(
        paneID: UUID,
        sessionID: UUID
    ) {
        guard sessions[paneID]?.activitySessionID == sessionID else {
            return
        }
        enqueueAgentActivityCommand { monitor in
            await monitor.recordSubmission(
                paneID: paneID,
                sessionID: sessionID
            )
        }
    }

    private func recordAgentActivityOutput(
        paneID: UUID,
        sessionID: UUID
    ) {
        guard sessions[paneID]?.activitySessionID == sessionID else {
            return
        }
        enqueueAgentActivityCommand { monitor in
            await monitor.recordOutput(
                paneID: paneID,
                sessionID: sessionID
            )
        }
    }

    private func stopAgentActivity(paneID: UUID, sessionID: UUID) {
        agentActivityRegistry.endSession(paneID: paneID, sessionID: sessionID)
        enqueueAgentActivityCommand { monitor in
            await monitor.unregister(
                paneID: paneID,
                sessionID: sessionID
            )
        }
    }

    private func enqueueAgentActivityCommand(
        _ command: @escaping (TerminalAgentActivityMonitor) async -> Void
    ) {
        let previousCommand = agentActivityCommandTail
        let monitor = agentActivityMonitor
        agentActivityCommandTail = Task {
            await previousCommand?.value
            await command(monitor)
        }
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

struct TerminalResizeLease: Hashable {
    fileprivate let id: UUID
    fileprivate let reason: TerminalResizeReason
}

private struct AnimatedLayoutTransition {
    let id: UUID
    var leases: [UUID: AnimatedLayoutLease]
}

private struct AnimatedLayoutLease {
    let terminal: TermuctiveTerminalView
    let lease: TerminalResizeLease
}

@MainActor
private final class TerminalFrameAnimator: NSObject {
    weak var terminal: TermuctiveTerminalView?

    init(terminal: TermuctiveTerminalView) {
        self.terminal = terminal
    }

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        terminal?.advanceInteractiveFrame(displayLink)
    }
}

final class TermuctiveTerminalView: LocalProcessTerminalView {
    var focusHandler: (() -> Void)?
    var localCommandHandler: ((TerminalLocalCommand) -> Void)?
    var outputHandler: ((ArraySlice<UInt8>) -> Void)?
    var activitySubmissionHandler: (() -> Void)?

    private var localCommandTracker = TerminalLocalCommandTracker()
    private var isForwardingTrackedText = false
    private var suppressEnhancedSubmitRelease = false
    private var hasPendingFocusRequest = false
    private var hasAttemptedAcceleratedRendering = false
    private var activeResizeLeases: [UUID: TerminalResizeReason] = [:]
    private var attachmentLeaseID: UUID?
    private var pendingFrameSize: NSSize?
    private var resizeDisplayLink: CADisplayLink?
    private var frameAnimator: TerminalFrameAnimator?
    private var interactivePresentationFrame: CGRect?
    private var mouseDownForCurrentGesture: NSEvent?
    private var shouldReportCurrentMouseClick = false
    private var didDragCurrentMouseGesture = false
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
        guard newSize != frame.size else {
            pendingFrameSize = nil
            if isAnimatedLayoutFrozen {
                resetPresentationGeometry()
            }
            return
        }
        guard isUsableFrameSize(newSize) else {
            return
        }
        guard attachmentLeaseID == nil else {
            pendingFrameSize = newSize
            return
        }
        guard hasInteractiveResizeLease else {
            pendingFrameSize = nil
            super.setFrameSize(newSize)
            notifyViewportOfFrameCommit()
            return
        }
        pendingFrameSize = newSize
        scheduleInteractiveFrameCommit()
    }

    deinit {
        resizeDisplayLink?.invalidate()
    }

    func commitInteractiveResizeFrameForTesting() {
        if isAnimatedLayoutFrozen {
            advanceAnimatedLayoutFrame(nil)
        } else {
            commitPendingFrameSizeIfPossible()
        }
    }

    var hasInteractiveFrameCommitScheduledForTesting: Bool {
        resizeDisplayLink != nil
    }

    var hasInteractivePresentationTransformForTesting: Bool {
        interactivePresentationFrame != nil
    }

    private var hasInteractiveResizeLease: Bool {
        activeResizeLeases.values.contains { $0 != .attachment }
    }

    private var isAnimatedLayoutFrozen: Bool {
        activeResizeLeases.values.contains(.animatedLayout)
    }

    private func scheduleInteractiveFrameCommit() {
        if resizeDisplayLink == nil {
            let animator = TerminalFrameAnimator(terminal: self)
            let displayLink = displayLink(
                target: animator,
                selector: #selector(TerminalFrameAnimator.displayLinkDidFire(_:))
            )
            displayLink.add(to: .main, forMode: .common)
            frameAnimator = animator
            resizeDisplayLink = displayLink
        }
        resizeDisplayLink?.isPaused = false
    }

    fileprivate func advanceInteractiveFrame(_ displayLink: CADisplayLink?) {
        if isAnimatedLayoutFrozen {
            advanceAnimatedLayoutFrame(displayLink)
            return
        }
        commitPendingFrameSizeIfPossible()
        if pendingFrameSize == nil {
            displayLink?.isPaused = true
        }
    }

    private func advanceAnimatedLayoutFrame(_ displayLink: CADisplayLink?) {
        guard isAnimatedLayoutFrozen,
            attachmentLeaseID == nil,
            pendingFrameSize != nil,
            let superview
        else {
            displayLink?.isPaused = true
            return
        }
        let targetFrame = superview.bounds
        let currentFrame = interactivePresentationFrame ?? frame
        let nextFrame = interpolatedFrame(
            from: currentFrame,
            to: targetFrame,
            progress: 0.42
        )
        interactivePresentationFrame = nextFrame
        let sourceSize = frame.size
        let scaleX = nextFrame.width / max(sourceSize.width, 1)
        let scaleY = nextFrame.height / max(sourceSize.height, 1)
        let transform = CATransform3DConcat(
            CATransform3DMakeTranslation(nextFrame.minX, nextFrame.minY, 0),
            CATransform3DMakeScale(scaleX, scaleY, 1)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.anchorPoint = .zero
        layer?.position = .zero
        layer?.transform = transform
        CATransaction.commit()
    }

    private func invalidateInteractiveFrameCommits() {
        resizeDisplayLink?.invalidate()
        resizeDisplayLink = nil
        frameAnimator = nil
    }

    private func commitLatestFrameAtResizeEnd() {
        if isAnimatedLayoutFrozen {
            if pendingFrameSize != nil {
                scheduleInteractiveFrameCommit()
            }
            return
        }
        commitPendingFrameSizeIfPossible()
        guard !hasInteractiveResizeLease else {
            return
        }
        invalidateInteractiveFrameCommits()
    }

    func requestFocus() {
        setWantsFocus(true)
    }

    func setWantsFocus(_ wantsFocus: Bool) {
        hasPendingFocusRequest = wantsFocus
        if wantsFocus {
            applyPendingFocusRequest()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enableAcceleratedRenderingIfAvailable()
        applyPendingFocusRequest()
    }

    override func mouseDown(with event: NSEvent) {
        focusHandler?()
        didDragCurrentMouseGesture = false
        mouseDownForCurrentGesture = event
        shouldReportCurrentMouseClick = allowMouseReporting
        allowMouseReporting = false
        super.mouseDown(with: event)
        if selectionActive {
            shouldReportCurrentMouseClick = false
        }
        allowMouseReporting = !selectionActive
    }

    override func mouseDragged(with event: NSEvent) {
        let shouldSeedSelection = !selectionActive
        didDragCurrentMouseGesture = true
        shouldReportCurrentMouseClick = false
        allowMouseReporting = false
        if shouldSeedSelection,
            let mouseDownForCurrentGesture
        {
            super.mouseDragged(with: mouseDownForCurrentGesture)
        }
        super.mouseDragged(with: event)
        allowMouseReporting = !selectionActive
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownForCurrentGesture = nil
            shouldReportCurrentMouseClick = false
            didDragCurrentMouseGesture = false
            allowMouseReporting = !selectionActive
        }

        if let mouseDownForCurrentGesture,
            shouldReportCurrentMouseClick,
            !didDragCurrentMouseGesture
        {
            allowMouseReporting = true
            super.mouseDown(with: mouseDownForCurrentGesture)
            super.mouseUp(with: event)
            return
        }

        allowMouseReporting = false
        super.mouseUp(with: event)
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        allowMouseReporting = !selectionActive
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
            activitySubmissionHandler?()
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
        super.dataReceived(slice: slice)
        outputHandler?(slice)
    }

    func submitApplicationLine(_ line: String) {
        guard !line.contains(where: \Character.isNewline) else {
            assertionFailure("A local command replacement must be a single line.")
            return
        }
        localCommandTracker.reset()
        let textBytes = Array(line.utf8)
        super.send(source: self, data: textBytes[...])
        let submitBytes = applicationSubmitBytes()
        super.send(source: self, data: submitBytes[...])
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

    private func applicationSubmitBytes() -> [UInt8] {
        let flags = getTerminal().keyboardEnhancementFlags
        if flags.contains(.disambiguate) || flags.contains(.reportAllKeys) {
            return Array("\u{1B}[13u".utf8)
        }
        return [0x0D]
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

    @discardableResult
    func beginInteractivePaneResize(
        reason: TerminalResizeReason = .divider
    ) -> TerminalResizeLease {
        let lease = TerminalResizeLease(id: UUID(), reason: reason)
        if reason == .attachment,
            let attachmentLeaseID
        {
            activeResizeLeases.removeValue(forKey: attachmentLeaseID)
        }
        activeResizeLeases[lease.id] = reason
        if reason == .attachment {
            attachmentLeaseID = lease.id
        }
        updateInteractiveRenderingMode()
        return lease
    }

    func endInteractivePaneResize(_ lease: TerminalResizeLease) {
        guard activeResizeLeases[lease.id] == lease.reason else {
            return
        }
        activeResizeLeases.removeValue(forKey: lease.id)
        if attachmentLeaseID == lease.id {
            attachmentLeaseID = nil
        }
        updateInteractiveRenderingMode()
        commitLatestFrameAtResizeEnd()
    }

    func cancelInteractivePaneResizes() {
        activeResizeLeases.removeAll()
        attachmentLeaseID = nil
        pendingFrameSize = nil
        resetPresentationGeometry()
        invalidateInteractiveFrameCommits()
        metalBufferingMode = .perRowPersistent
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

    private func updateInteractiveRenderingMode() {
        let needsFullFrameAggregation = activeResizeLeases.values.contains { reason in
            reason == .divider || reason == .windowLiveResize
        }
        metalBufferingMode =
            needsFullFrameAggregation ? .perFrameAggregated : .perRowPersistent
    }

    private func commitPendingFrameSizeIfPossible() {
        guard attachmentLeaseID == nil,
            let pendingFrameSize
        else {
            return
        }
        self.pendingFrameSize = nil
        guard pendingFrameSize != frame.size,
            isUsableFrameSize(pendingFrameSize)
        else {
            return
        }
        resetPresentationGeometry()
        super.setFrameSize(pendingFrameSize)
        notifyViewportOfFrameCommit()
    }

    private func notifyViewportOfFrameCommit() {
        (superview as? TerminalViewportView)?.terminalFrameDidCommit()
    }

    private func interpolatedFrame(
        from currentFrame: CGRect,
        to targetFrame: CGRect,
        progress: CGFloat
    ) -> CGRect {
        CGRect(
            x: currentFrame.minX + (targetFrame.minX - currentFrame.minX) * progress,
            y: currentFrame.minY + (targetFrame.minY - currentFrame.minY) * progress,
            width: currentFrame.width + (targetFrame.width - currentFrame.width) * progress,
            height: currentFrame.height + (targetFrame.height - currentFrame.height) * progress
        )
    }

    private func resetPresentationGeometry() {
        interactivePresentationFrame = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.transform = CATransform3DIdentity
        CATransaction.commit()
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

struct TerminalShellConfiguration {
    let executable: String
    let execName: String
    let environment: [String]

    init(
        executable: String,
        execName: String,
        baseEnvironment: [String: String]
    ) {
        self.executable = executable
        self.execName = execName
        var resolvedEnvironment = baseEnvironment
        resolvedEnvironment["TERM"] = "xterm-256color"
        resolvedEnvironment["COLORTERM"] = "truecolor"
        resolvedEnvironment["TERM_PROGRAM"] = "Termuctive"
        resolvedEnvironment["TERM_PROGRAM_VERSION"] =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        environment = resolvedEnvironment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    static var live: TerminalShellConfiguration {
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let executable =
            FileManager.default.isExecutableFile(atPath: configured)
            ? configured
            : "/bin/zsh"
        return TerminalShellConfiguration(
            executable: executable,
            execName: "-\(URL(fileURLWithPath: executable).lastPathComponent)",
            baseEnvironment: ProcessInfo.processInfo.environment
        )
    }
}

private final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    private static let agentOutputSignalIntervalNanoseconds: UInt64 = 100_000_000

    let paneID: UUID
    let view: TermuctiveTerminalView
    private(set) var startedAt = Date()
    private(set) var activitySessionID: UUID?

    private var pane: TerminalPane
    private let shellConfiguration: TerminalShellConfiguration
    private var outputPDFTracker = TerminalOutputPDFTracker()
    private var outputActivityClassifier = TerminalOutputActivityClassifier()
    private var lastAgentOutputSignalTime: UInt64?
    private let onTitleChange: (UUID, String) -> Void
    private let onDirectoryChange: (UUID, String) -> Void
    private let onLocalCommand: (UUID, TerminalLocalCommand) -> Void
    private let onPDFPathDetected: (UUID, URL) -> Void
    private let captureAgentShellIdentity: (Int32) -> AgentShellIdentity?
    private let onAgentActivityStarted:
        (
            UUID,
            Int32,
            AgentShellIdentity,
            UUID
        ) -> Void
    private let onAgentActivitySubmission: (UUID, UUID) -> Void
    private let onAgentActivityOutput: (UUID, UUID) -> Void
    private let onAgentActivityStopped: (UUID, UUID) -> Void
    private let onTermination: (UUID, Int32?) -> Void

    init(
        pane: TerminalPane,
        fontSize: CGFloat,
        theme: TerminalTheme,
        shellConfiguration: TerminalShellConfiguration,
        onFocus: @escaping (UUID) -> Void,
        onTitleChange: @escaping (UUID, String) -> Void,
        onDirectoryChange: @escaping (UUID, String) -> Void,
        onLocalCommand: @escaping (UUID, TerminalLocalCommand) -> Void,
        onPDFPathDetected: @escaping (UUID, URL) -> Void,
        captureAgentShellIdentity: @escaping (Int32) -> AgentShellIdentity?,
        onAgentActivityStarted:
            @escaping (
                UUID,
                Int32,
                AgentShellIdentity,
                UUID
            ) -> Void,
        onAgentActivitySubmission: @escaping (UUID, UUID) -> Void,
        onAgentActivityOutput: @escaping (UUID, UUID) -> Void,
        onAgentActivityStopped: @escaping (UUID, UUID) -> Void,
        onTermination: @escaping (UUID, Int32?) -> Void
    ) {
        paneID = pane.id
        self.pane = pane
        self.shellConfiguration = shellConfiguration
        self.onTitleChange = onTitleChange
        self.onDirectoryChange = onDirectoryChange
        self.onLocalCommand = onLocalCommand
        self.onPDFPathDetected = onPDFPathDetected
        self.captureAgentShellIdentity = captureAgentShellIdentity
        self.onAgentActivityStarted = onAgentActivityStarted
        self.onAgentActivitySubmission = onAgentActivitySubmission
        self.onAgentActivityOutput = onAgentActivityOutput
        self.onAgentActivityStopped = onAgentActivityStopped
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
            self?.trackOutput(bytes)
        }
        view.activitySubmissionHandler = { [weak self] in
            self?.recordAgentActivitySubmission()
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
        guard !view.process.running else {
            return true
        }
        endAgentActivitySession()
        return start(pane: pane)
    }

    func terminate() {
        endAgentActivitySession()
        view.cancelInteractivePaneResizes()
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

    func submitApplicationLine(_ line: String) {
        view.submitApplicationLine(line)
    }

    func mostRecentVisiblePDF() -> URL? {
        let output = String(
            decoding: view.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
        return TerminalOutputPDFTracker.detectedURLs(
            in: output,
            workingDirectory: pane.workingDirectory
        ).last
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
        endAgentActivitySession()
        onTermination(paneID, exitCode)
    }

    private func start(pane: TerminalPane) -> Bool {
        guard !view.process.running else {
            return true
        }

        startedAt = Date()
        outputPDFTracker = TerminalOutputPDFTracker()
        outputActivityClassifier = TerminalOutputActivityClassifier()
        lastAgentOutputSignalTime = nil
        let currentDirectory = Self.validDirectory(pane.workingDirectory)
        if currentDirectory != pane.workingDirectory {
            self.pane.workingDirectory = currentDirectory
            onDirectoryChange(paneID, currentDirectory)
        }
        view.startProcess(
            executable: shellConfiguration.executable,
            environment: shellConfiguration.environment,
            execName: shellConfiguration.execName,
            currentDirectory: currentDirectory
        )
        guard view.process.running else {
            return false
        }
        let shellPID = view.process.shellPid
        guard let shellIdentity = captureAgentShellIdentity(shellPID) else {
            return true
        }
        let sessionID = UUID()
        activitySessionID = sessionID
        onAgentActivityStarted(paneID, shellPID, shellIdentity, sessionID)
        return true
    }

    private func trackOutput(_ bytes: ArraySlice<UInt8>) {
        trackPDFs(in: bytes)
        guard outputActivityClassifier.consume(bytes) else {
            return
        }
        recordAgentActivityOutput()
    }

    private func recordAgentActivitySubmission() {
        guard let activitySessionID else {
            return
        }
        onAgentActivitySubmission(paneID, activitySessionID)
    }

    private func recordAgentActivityOutput() {
        guard let activitySessionID else {
            return
        }
        let currentTime = DispatchTime.now().uptimeNanoseconds
        guard
            lastAgentOutputSignalTime.map({ previousTime in
                currentTime >= previousTime
                    && currentTime - previousTime >= Self.agentOutputSignalIntervalNanoseconds
            }) ?? true
        else {
            return
        }
        lastAgentOutputSignalTime = currentTime
        onAgentActivityOutput(paneID, activitySessionID)
    }

    private func endAgentActivitySession() {
        guard let activitySessionID else {
            return
        }
        self.activitySessionID = nil
        onAgentActivityStopped(paneID, activitySessionID)
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
