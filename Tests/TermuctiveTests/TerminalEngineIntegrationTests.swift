import AppKit
import Combine
import Metal
import SwiftTerm
import XCTest

@testable import Termuctive

@MainActor
final class TerminalEngineIntegrationTests: XCTestCase {
    func testTermuctiveSessionAcceptsInteractiveInput() async throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        terminal.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let marker = "TERMUCTIVE_INTERACTIVE_\(UUID().uuidString.prefix(8))"
        terminal.send(txt: "printf '\(marker)\\n'\n")

        let output = try await terminalOutput(
            from: terminal,
            containing: [marker],
            timeout: 5
        )
        XCTAssertTrue(
            output.contains(marker),
            "Terminal output was \(output.debugDescription)"
        )
    }

    func testFocusRequestedBeforeAttachmentIsAppliedAfterAttachment() async throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        sessions.focus(paneID: pane.id)
        XCTAssertNil(terminal.window)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === terminal)
    }

    func testAttachedTerminalUsesAcceleratedRendererWhenMetalIsAvailable() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)

        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertTrue(terminal.isUsingMetalRenderer)
        }
    }

    func testTerminalFontSizeStartsCompactAndStaysWithinBounds() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        XCTAssertEqual(terminal.font.pointSize, 11)
        sessions.increaseFontSize()
        XCTAssertEqual(terminal.font.pointSize, 12)
        sessions.decreaseFontSize()
        XCTAssertEqual(terminal.font.pointSize, 11)

        for _ in 0..<40 {
            sessions.decreaseFontSize()
        }
        XCTAssertEqual(terminal.font.pointSize, 8)
        XCTAssertFalse(sessions.canDecreaseFontSize)

        for _ in 0..<40 {
            sessions.increaseFontSize()
        }
        XCTAssertEqual(terminal.font.pointSize, 32)
        XCTAssertFalse(sessions.canIncreaseFontSize)
    }

    func testTerminalUsesStandardMacOSFontSmoothing() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        XCTAssertTrue(terminal.fontSmoothing)
    }

    func testInteractiveDividerResizeCoalescesToDisplayFrames() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let processDelegate = TerminalResizeTestDelegate()
        terminal.processDelegate = processDelegate
        terminal.startProcess(executable: "/bin/sh")
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }

        let lease = terminal.beginInteractivePaneResize()
        for width in stride(from: 600, through: 440, by: -20) {
            let size = NSSize(width: CGFloat(width), height: 420)
            terminal.setFrameSize(size)
        }

        XCTAssertEqual(terminal.frame.size, NSSize(width: 640, height: 480))
        XCTAssertEqual(processDelegate.resizeEvents.count, 0)

        terminal.commitInteractiveResizeFrameForTesting()

        XCTAssertEqual(terminal.frame.size, NSSize(width: 440, height: 420))
        XCTAssertEqual(processDelegate.resizeEvents.count, 1)

        terminal.setFrameSize(NSSize(width: 420, height: 400))
        terminal.endInteractivePaneResize(lease)

        XCTAssertEqual(terminal.frame.size, NSSize(width: 420, height: 400))
        XCTAssertEqual(processDelegate.resizeEvents.count, 2)
    }

    func testReversingAnimatedLayoutKeepsOnePTYResizeTransaction() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)
        terminal.cancelInteractivePaneResizes()
        let processDelegate = TerminalResizeTestDelegate()
        terminal.processDelegate = processDelegate

        let firstTransition = sessions.beginAnimatedLayoutTransition()
        terminal.setFrameSize(NSSize(width: 520, height: 480))
        terminal.commitInteractiveResizeFrameForTesting()
        let reversedTransition = sessions.beginAnimatedLayoutTransition()

        sessions.finishAnimatedLayoutTransition(firstTransition)
        XCTAssertEqual(processDelegate.resizeEvents.count, 0)

        terminal.setFrameSize(NSSize(width: 600, height: 480))
        terminal.commitInteractiveResizeFrameForTesting()
        XCTAssertEqual(processDelegate.resizeEvents.count, 0)

        sessions.finishAnimatedLayoutTransition(reversedTransition)

        XCTAssertEqual(terminal.frame.size, NSSize(width: 600, height: 480))
        XCTAssertEqual(processDelegate.resizeEvents.count, 1)
    }

    func testAnimatedLayoutReturningToOriginalSizeClearsPresentationTransform() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let container = NSView(frame: terminal.frame)
        container.addSubview(terminal)
        let transition = terminal.beginInteractivePaneResize(reason: .animatedLayout)

        container.setFrameSize(NSSize(width: 500, height: 480))
        terminal.setFrameSize(container.bounds.size)
        terminal.commitInteractiveResizeFrameForTesting()
        XCTAssertTrue(terminal.hasInteractivePresentationTransformForTesting)

        container.setFrameSize(NSSize(width: 640, height: 480))
        terminal.setFrameSize(container.bounds.size)
        terminal.endInteractivePaneResize(transition)

        XCTAssertFalse(terminal.hasInteractivePresentationTransformForTesting)
        XCTAssertTrue(CATransform3DIsIdentity(terminal.layer?.transform ?? CATransform3DIdentity))
        XCTAssertEqual(terminal.frame.size, NSSize(width: 640, height: 480))
    }

    func testAnimatedLayoutKeepsRowPersistentBufferingWhileShellOutputStreams() async throws {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let container = NSView(frame: terminal.frame)
        container.addSubview(terminal)
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-f"],
            execName: "zsh"
        )
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }
        terminal.send(
            txt: "PROMPT='(base) draingang@Ahmets-MacBook-Air-2 fylm-tv % '; "
                + "PROMPT_EOL_MARK='%'; print -r -- TERMUCTIVE_READY\n"
        )
        _ = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_READY"],
            timeout: 5
        )

        let transition = terminal.beginInteractivePaneResize(
            reason: .animatedLayout
        )
        switch terminal.metalBufferingMode {
        case .perRowPersistent:
            break
        case .perFrameAggregated:
            XCTFail("Presentation-only layout must not replace the interactive-shell row cache.")
        }

        container.setFrameSize(NSSize(width: 880, height: 480))
        terminal.setFrameSize(container.bounds.size)
        terminal.commitInteractiveResizeFrameForTesting()
        terminal.send(txt: "printf 'TERMUCTIVE_EXACT_REVERSAL_INPUT_OK\\n'\n")
        _ = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_EXACT_REVERSAL_INPUT_OK"],
            timeout: 5
        )

        container.setFrameSize(NSSize(width: 640, height: 480))
        terminal.setFrameSize(container.bounds.size)
        terminal.endInteractivePaneResize(transition)
        try await Task.sleep(nanoseconds: 200_000_000)

        let output = String(
            decoding: terminal.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertFalse(terminal.hasInteractivePresentationTransformForTesting)
        XCTAssertFalse(
            lines.contains("%"),
            "A zsh partial-line marker remained after the exact reversal: \(output)"
        )
    }

    func testAnimatedResizeKeepsZshOutputStableUntilSettlement() async throws {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600)
        )
        let processDelegate = TerminalResizeTestDelegate()
        terminal.processDelegate = processDelegate
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-f"],
            execName: "zsh"
        )
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }
        terminal.send(
            txt: "PROMPT='TERMUCTIVE_PROMPT % '; "
                + "PROMPT_EOL_MARK='%'; "
                + "print -r -- TERMUCTIVE_READY\n"
        )
        _ = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_READY"],
            timeout: 5
        )
        processDelegate.reset()

        let transition = terminal.beginInteractivePaneResize(
            reason: .animatedLayout
        )
        for width in stride(from: 860, through: 620, by: -40) {
            terminal.setFrameSize(NSSize(width: CGFloat(width), height: 600))
            terminal.commitInteractiveResizeFrameForTesting()
        }
        terminal.send(txt: "print -r -- FROZEN_REVERSAL_INPUT_OK\n")
        _ = try await terminalOutput(
            from: terminal,
            containing: ["FROZEN_REVERSAL_INPUT_OK"],
            timeout: 5
        )

        XCTAssertEqual(processDelegate.resizeEvents.count, 0)

        for width in stride(from: 660, through: 820, by: 40) {
            terminal.setFrameSize(NSSize(width: CGFloat(width), height: 600))
            terminal.commitInteractiveResizeFrameForTesting()
        }
        terminal.endInteractivePaneResize(transition)
        let expectedSize =
            "TERMUCTIVE_SIZE_\(terminal.getTerminal().rows) "
            + "\(terminal.getTerminal().cols)"
        terminal.send(
            txt: "print -n -- TERMUCTIVE_SIZE_; stty size; "
                + "print -r -- TERMUCTIVE_AFTER_REVERSAL\n"
        )
        let output = try await terminalOutput(
            from: terminal,
            containing: [expectedSize, "TERMUCTIVE_AFTER_REVERSAL"],
            timeout: 5
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        XCTAssertEqual(processDelegate.resizeEvents.count, 1)
        XCTAssertTrue(output.contains(expectedSize))
        XCTAssertFalse(
            lines.contains("%"),
            "A zsh partial-line marker remained after resize reversal: \(output)"
        )
    }

    func testOverlappingResizeTransactionsWaitForEveryTransition() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let processDelegate = TerminalResizeTestDelegate()
        terminal.processDelegate = processDelegate
        terminal.startProcess(executable: "/bin/sh")
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }

        let attachmentLease = terminal.beginInteractivePaneResize(reason: .attachment)
        let dividerLease = terminal.beginInteractivePaneResize(reason: .divider)
        terminal.setFrameSize(NSSize(width: 500, height: 400))
        terminal.endInteractivePaneResize(dividerLease)

        XCTAssertEqual(terminal.frame.size, NSSize(width: 640, height: 480))
        XCTAssertEqual(processDelegate.resizeEvents.count, 0)

        terminal.endInteractivePaneResize(attachmentLease)

        XCTAssertEqual(terminal.frame.size, NSSize(width: 500, height: 400))
        XCTAssertEqual(processDelegate.resizeEvents.count, 1)
    }

    func testStaleAttachmentLeaseCannotReleaseNewAttachment() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let initialSize = terminal.frame.size
        let staleLease = terminal.beginInteractivePaneResize(reason: .attachment)
        let currentLease = terminal.beginInteractivePaneResize(reason: .attachment)

        terminal.setFrameSize(NSSize(width: 500, height: 400))
        terminal.endInteractivePaneResize(staleLease)

        XCTAssertEqual(terminal.frame.size, initialSize)

        terminal.endInteractivePaneResize(currentLease)

        XCTAssertEqual(terminal.frame.size, NSSize(width: 500, height: 400))
    }

    func testAttachmentReturningToSettledSizeCancelsStalePendingGeometry() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let lease = terminal.beginInteractivePaneResize(reason: .attachment)

        terminal.setFrameSize(NSSize(width: 500, height: 400))
        terminal.setFrameSize(NSSize(width: 640, height: 480))
        terminal.endInteractivePaneResize(lease)

        XCTAssertEqual(terminal.frame.size, NSSize(width: 640, height: 480))
    }

    func testRepeatedTerminalSizeDoesNotRequestAnotherDraw() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        terminal.needsDisplay = false

        for _ in 0..<500 {
            terminal.setFrameSize(NSSize(width: 640, height: 480))
        }

        XCTAssertFalse(terminal.needsDisplay)
        XCTAssertEqual(terminal.frame.size, NSSize(width: 640, height: 480))
    }

    func testInteractiveResizeRestoresPersistentMetalBuffering() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )

        let lease = terminal.beginInteractivePaneResize(reason: .divider)
        switch terminal.metalBufferingMode {
        case .perFrameAggregated:
            break
        case .perRowPersistent:
            XCTFail("Interactive resizing should aggregate the visible frame.")
        }

        terminal.endInteractivePaneResize(lease)
        switch terminal.metalBufferingMode {
        case .perRowPersistent:
            break
        case .perFrameAggregated:
            XCTFail("Settled terminals should restore row-persistent buffering.")
        }
    }

    func testPresentationOnlyResizeAggregatesOnlyWhileLogicalResizeOverlaps() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )

        let animatedLease = terminal.beginInteractivePaneResize(reason: .animatedLayout)
        assertRowPersistentBuffering(terminal)

        terminal.setFrameSize(NSSize(width: 520, height: 480))
        assertRowPersistentBuffering(terminal)

        let dividerLease = terminal.beginInteractivePaneResize(reason: .divider)
        assertAggregatedBuffering(terminal)

        terminal.endInteractivePaneResize(dividerLease)
        assertRowPersistentBuffering(terminal)

        terminal.setFrameSize(NSSize(width: 640, height: 480))
        terminal.endInteractivePaneResize(animatedLease)
        assertRowPersistentBuffering(terminal)
    }

    func testViewportReparentingReleasesItsWindowResizeLease() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let viewport = TerminalViewportView(terminal: terminal)
        viewport.viewWillStartLiveResize()
        let replacement = NSView(frame: viewport.bounds)
        terminal.removeFromSuperview()
        replacement.addSubview(terminal)

        viewport.prepareForDetachment()

        switch terminal.metalBufferingMode {
        case .perRowPersistent:
            break
        case .perFrameAggregated:
            XCTFail("A detached viewport must release the lease it owns.")
        }
    }

    func testVerticalResizeCommitKeepsTerminalInsideViewport() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let viewport = TerminalViewportView(terminal: terminal)
        viewport.frame = terminal.frame
        terminal.cancelInteractivePaneResizes()
        viewport.layoutSubtreeIfNeeded()
        let lease = terminal.beginInteractivePaneResize(reason: .windowLiveResize)

        viewport.setFrameSize(NSSize(width: 640, height: 600))
        viewport.layoutSubtreeIfNeeded()
        terminal.commitInteractiveResizeFrameForTesting()

        XCTAssertEqual(terminal.frame, viewport.bounds)
        XCTAssertTrue(viewport.bounds.contains(terminal.frame))

        terminal.endInteractivePaneResize(lease)
    }

    func testDisplayLinkIsInvalidatedAfterResizeEnds() {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let lease = terminal.beginInteractivePaneResize(reason: .divider)
        terminal.setFrameSize(NSSize(width: 500, height: 400))

        XCTAssertTrue(terminal.hasInteractiveFrameCommitScheduledForTesting)

        terminal.endInteractivePaneResize(lease)

        XCTAssertFalse(terminal.hasInteractiveFrameCommitScheduledForTesting)
    }

    func testRemovingPaneDuringAnimatedTransitionCancelsCapturedResizeOwner() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)
        terminal.cancelInteractivePaneResizes()

        let transitionID = sessions.beginAnimatedLayoutTransition()
        terminal.setFrameSize(NSSize(width: 500, height: 400))
        XCTAssertTrue(terminal.hasInteractiveFrameCommitScheduledForTesting)

        sessions.reconcile(validPaneIDs: [])

        XCTAssertFalse(terminal.hasInteractiveFrameCommitScheduledForTesting)
        switch terminal.metalBufferingMode {
        case .perRowPersistent:
            break
        case .perFrameAggregated:
            XCTFail("Removing a pane left its interactive rendering mode active.")
        }
        sessions.finishAnimatedLayoutTransition(transitionID)
    }

    func testCodexStyleStreamingDoesNotDelayEscapeInput() async throws {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600)
        )
        let processDelegate = TerminalTestDelegate(testCase: self)
        terminal.processDelegate = processDelegate
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)
        window.makeFirstResponder(terminal)
        terminal.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "saved_tty=$(stty -g); stty raw -echo; "
                    + "printf 'TERMUCTIVE_ESCAPE_READY\\n'; "
                    + "escape_byte=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' '); "
                    + "stty \"$saved_tty\"; "
                    + "printf '\\nTERMUCTIVE_ESCAPE_BYTE_%s\\n' \"$escape_byte\"",
            ]
        )
        _ = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_ESCAPE_READY"],
            timeout: 5
        )

        let escapeEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            terminal.keyDown(with: escapeEvent)
        }

        let codexFrame = Array(
            "\u{1B}[?25l\u{1B}[2K\rCodex is generating output/report.pdf".utf8
        )
        for _ in 0..<2_000 {
            terminal.dataReceived(slice: codexFrame[...])
        }

        let output = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_ESCAPE_BYTE_1b"],
            timeout: 5
        )
        await fulfillment(of: [processDelegate.terminated], timeout: 5)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertTrue(output.contains("TERMUCTIVE_ESCAPE_BYTE_1b"))
        XCTAssertLessThan(
            elapsed,
            2,
            "Escape was delayed for \(elapsed) seconds while terminal output was streaming."
        )
    }

    func testMakePDFReplacesTheTypedCommandWithOneCodexRequest() async throws {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600)
        )
        let processDelegate = TerminalTestDelegate(testCase: self)
        terminal.processDelegate = processDelegate
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }

        let request = "TERMUCTIVE LEARNING REQUEST"
        let expectedBytes = Array("/makepdf".utf8) + [0x15] + Array(request.utf8) + [0x0D]
        let expectedHex = expectedBytes.map { String(format: "%02x", $0) }.joined()
        terminal.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "saved_tty=$(stty -g); stty raw -echo; "
                    + "printf 'TERMUCTIVE_MAKEPDF_READY\\n'; "
                    + "captured=$(dd bs=1 count=\(expectedBytes.count) 2>/dev/null "
                    + "| od -An -tx1 | tr -d '[:space:]'); "
                    + "stty \"$saved_tty\"; "
                    + "printf '\\nTERMUCTIVE_MAKEPDF_BYTES_%s\\n' \"$captured\"",
            ]
        )
        _ = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_MAKEPDF_READY"],
            timeout: 5
        )

        var handledCommands: [TerminalLocalCommand] = []
        terminal.localCommandHandler = { command in
            handledCommands.append(command)
            terminal.submitApplicationLine(request)
        }
        terminal.insertText(
            "/makepdf",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        terminal.send(source: terminal, data: [0x0D][...])

        _ = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_MAKEPDF_BYTES_"],
            timeout: 5
        )
        await fulfillment(of: [processDelegate.terminated], timeout: 5)
        let output = String(
            decoding: terminal.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
        let unwrappedOutput = output.filter { !$0.isWhitespace }

        XCTAssertEqual(handledCommands, [.makeLearningPDF])
        XCTAssertTrue(
            unwrappedOutput.contains("TERMUCTIVE_MAKEPDF_BYTES_\(expectedHex)"),
            "Terminal output was \(output.debugDescription)"
        )
    }

    func testMouseClickReportingStillReachesTerminalApplication() async throws {
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600)
        )
        let processDelegate = TerminalTestDelegate(testCase: self)
        terminal.processDelegate = processDelegate
        defer {
            if terminal.process.running {
                terminal.terminate()
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)
        window.makeFirstResponder(terminal)
        terminal.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "saved_tty=$(stty -g); stty raw -echo; "
                    + "printf '\\033[?1000hTERMUCTIVE_MOUSE_READY\\n'; "
                    + "mouse_byte=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' '); "
                    + "stty \"$saved_tty\"; "
                    + "printf '\\033[?1000l\\nTERMUCTIVE_MOUSE_BYTE_%s\\n' \"$mouse_byte\"",
            ]
        )
        _ = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_MOUSE_READY"],
            timeout: 5
        )
        guard case .vt200 = terminal.getTerminal().mouseMode else {
            XCTFail("The terminal application did not enable VT200 mouse reporting.")
            return
        }

        let location = NSPoint(x: 40, y: terminal.bounds.height - 20)
        terminal.mouseDown(
            with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: location, in: window))
        )
        terminal.mouseUp(
            with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: location, in: window))
        )

        let output = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_MOUSE_BYTE_1b"],
            timeout: 2
        )
        await fulfillment(of: [processDelegate.terminated], timeout: 5)

        XCTAssertTrue(output.contains("TERMUCTIVE_MOUSE_BYTE_1b"))
    }

    func testManualSelectionSurvivesStreamingOutput() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminal.frame = container.bounds
        container.addSubview(terminal)

        terminal.dataReceived(
            slice: Array(
                "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[2J\u{1B}[H"
                    .appending("first selectable line\r\nsecond selectable line")
                    .utf8
            )[...]
        )
        let rowHeight =
            terminal.getOptimalFrameSize().height
            / CGFloat(terminal.getTerminal().rows)
        let start = NSPoint(x: 8, y: terminal.bounds.height - (rowHeight * 0.5))
        let end = NSPoint(x: 180, y: terminal.bounds.height - (rowHeight * 1.5))
        terminal.mouseDown(
            with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: start, in: window))
        )
        terminal.mouseDragged(
            with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: end, in: window))
        )
        terminal.mouseUp(
            with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: end, in: window))
        )

        let buffer = String(
            decoding: terminal.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
        let selectedText = terminal.getSelection()
        XCTAssertTrue(terminal.selectionActive)
        XCTAssertFalse(
            selectedText?.isEmpty ?? true,
            "The drag selected no text from buffer: \(buffer)"
        )
        XCTAssertFalse(terminal.allowMouseReporting)

        terminal.dataReceived(slice: Array("\nstreamed response line\n".utf8)[...])

        XCTAssertTrue(
            terminal.selectionActive,
            "Streaming output cleared the user's active terminal selection."
        )
        XCTAssertEqual(terminal.getSelection(), selectedText)

        terminal.selectNone()

        XCTAssertTrue(terminal.allowMouseReporting)
    }

    func testMovePDFPrefersLatestVisibleCodexPathOverStaleDetection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termuctive-visible-pdf-\(UUID().uuidString)")
        let outputDirectory = directory.appendingPathComponent("output/pdf", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let stalePDF = directory.appendingPathComponent("old-report.pdf")
        let visiblePDF = outputDirectory.appendingPathComponent(
            "biohub_phase9_appearance_cnn_foundation.pdf"
        )
        try Data("%PDF-stale".utf8).write(to: stalePDF)
        try Data("%PDF-visible".utf8).write(to: visiblePDF)

        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: directory)
        let sourcePaneID = try XCTUnwrap(store.focusedPaneID)
        let sourcePane = try XCTUnwrap(
            store.selectedSpace?.layout.terminal(withID: sourcePaneID)
        )
        let sessions = TerminalSessionPool(store: store)
        let terminal = sessions.terminalView(for: sourcePane)
        defer {
            sessions.terminateAll()
        }
        terminal.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        terminal.dataReceived(
            slice: Array("Previously opened \(stalePDF.path)\n".utf8)[...]
        )
        terminal.dataReceived(
            slice: Array("Opened latest Biohub PDF: output/pdf/biohub_phase9_X".utf8)[...]
        )
        terminal.dataReceived(
            slice: Array("\u{8}appearance_cnn_foundation.pdf. It is 14 pages.\n".utf8)[...]
        )
        await Task.yield()

        let renderedOutput = String(
            decoding: terminal.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
        XCTAssertTrue(
            renderedOutput.contains("output/pdf/biohub_phase9_appearance_cnn_foundation.pdf")
        )

        store.splitFocusedPane(axis: .horizontal)
        let targetPaneID = try XCTUnwrap(store.selectedSpace?.layout.orderedTerminalIDs.last)
        sessions.moveRecentPDF(fromPaneID: sourcePaneID, placement: .right)

        XCTAssertEqual(
            sessions.previewURL(for: targetPaneID),
            visiblePDF.standardizedFileURL
        )
    }

    func testTerminalThemeChangesWithoutReplacingTheSessionView() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store, terminalTheme: .light)
        let terminal = sessions.terminalView(for: pane)
        defer {
            sessions.terminateAll()
        }

        XCTAssertEqual(terminal.nativeBackgroundColor, TerminalTheme.light.backgroundColor)

        sessions.setTerminalTheme(.dark)

        XCTAssertTrue(terminal === sessions.terminalView(for: pane))
        XCTAssertEqual(terminal.nativeForegroundColor, TerminalTheme.dark.foregroundColor)
        XCTAssertEqual(terminal.nativeBackgroundColor, TerminalTheme.dark.backgroundColor)
    }

    func testCreatingTerminalSessionDoesNotPublishDuringViewConstruction() throws {
        let persistence = TerminalTestPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.addProject(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let layout = try XCTUnwrap(store.selectedSpace?.layout)
        let pane = try XCTUnwrap(layout.terminal(withID: layout.firstTerminalID))
        let sessions = TerminalSessionPool(store: store)
        var publicationCount = 0
        let observation = sessions.objectWillChange.sink {
            publicationCount += 1
        }
        defer {
            observation.cancel()
            sessions.terminateAll()
        }

        _ = sessions.terminalView(for: pane)

        XCTAssertEqual(publicationCount, 0)
    }

    func testShellOutputAndWorkingDirectoryReachTerminalBuffer() async throws {
        let identifier = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("termuctive test \(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let expectedDirectory = directory.resolvingSymlinksInPath().path

        let terminal = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let processDelegate = TerminalTestDelegate(testCase: self)
        terminal.processDelegate = processDelegate
        terminal.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'TERMUCTIVE_PTY_OK\\n'; pwd"],
            currentDirectory: directory.path
        )

        await fulfillment(of: [processDelegate.terminated], timeout: 5)

        let output = try await terminalOutput(
            from: terminal,
            containing: ["TERMUCTIVE_PTY_OK", expectedDirectory],
            timeout: 2
        )
        XCTAssertTrue(
            output.contains("TERMUCTIVE_PTY_OK"),
            "Terminal output was \(output.debugDescription)"
        )
        XCTAssertTrue(
            output.contains(expectedDirectory),
            "Terminal output was \(output.debugDescription)"
        )
    }

    private func assertRowPersistentBuffering(
        _ terminal: TermuctiveTerminalView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch terminal.metalBufferingMode {
        case .perRowPersistent:
            break
        case .perFrameAggregated:
            XCTFail("Expected row-persistent terminal buffering.", file: file, line: line)
        }
    }

    private func assertAggregatedBuffering(
        _ terminal: TermuctiveTerminalView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch terminal.metalBufferingMode {
        case .perFrameAggregated:
            break
        case .perRowPersistent:
            XCTFail("Expected full-frame terminal buffering.", file: file, line: line)
        }
    }

    private func terminalOutput(
        from terminal: LocalProcessTerminalView,
        containing markers: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let data = terminal.getTerminal().getBufferAsData()
            let output = String(decoding: data, as: UTF8.self)
            if markers.allSatisfy({ output.contains($0) }) {
                return output
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return String(
            decoding: terminal.getTerminal().getBufferAsData(),
            as: UTF8.self
        )
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }
}

private final class TerminalTestPersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}

private final class TerminalTestDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let terminated: XCTestExpectation

    init(testCase: XCTestCase) {
        terminated = testCase.expectation(description: "Shell process terminated")
    }

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminated.fulfill()
    }
}

private final class TerminalResizeTestDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private(set) var resizeEvents: [(columns: Int, rows: Int)] = []

    func reset() {
        resizeEvents.removeAll()
    }

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {
        resizeEvents.append((newCols, newRows))
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
