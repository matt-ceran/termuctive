import AppKit
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
