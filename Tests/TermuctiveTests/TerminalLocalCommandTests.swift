import Foundation
import XCTest

@testable import Termuctive

final class TerminalLocalCommandTests: XCTestCase {
    func testLegacyAndEnhancedReturnAreRecognizedAsSubmission() {
        XCTAssertEqual(TerminalControlInput(bytes: [0x0D][...]), .submit(enhanced: false))
        XCTAssertEqual(
            TerminalControlInput(bytes: Array("\u{1B}[13u".utf8)[...]),
            .submit(enhanced: true)
        )
        XCTAssertEqual(
            TerminalControlInput(bytes: Array("\u{1B}[13;1:3u".utf8)[...]),
            .enhancedRelease(keyCode: 13)
        )
        XCTAssertEqual(
            TerminalControlInput(bytes: Array("\u{1B}[1;1R".utf8)[...]),
            .other
        )
    }

    func testMovePDFCommandsAreRecognizedBeforeSubmissionReachesTheProcess() {
        let commands: [(String, PDFPanePlacement)] = [
            ("/movepdf", .automatic),
            ("/movepdfleft", .left),
            ("/movepdfright", .right),
        ]

        for (input, placement) in commands {
            var tracker = TerminalLocalCommandTracker()
            tracker.insert(input)

            XCTAssertEqual(tracker.commandForSubmission(), .moveRecentPDF(placement))
        }
    }

    func testUnknownSlashCommandIsNotIntercepted() {
        var tracker = TerminalLocalCommandTracker()
        tracker.insert("/status")

        XCTAssertNil(tracker.commandForSubmission())
    }

    func testBackspaceUpdatesTheTrackedCommandLine() {
        var tracker = TerminalLocalCommandTracker()
        tracker.insert("/movepdfrighx")
        tracker.deleteBackward()
        tracker.insert("t")

        XCTAssertEqual(tracker.commandForSubmission(), .moveRecentPDF(.right))
    }

    func testCursorMovementInvalidatesRecognitionUntilTheNextSubmission() {
        var tracker = TerminalLocalCommandTracker()
        tracker.insert("/movepdfright")
        tracker.invalidate()

        XCTAssertNil(tracker.commandForSubmission())

        tracker.insert("/movepdfleft")
        XCTAssertEqual(tracker.commandForSubmission(), .moveRecentPDF(.left))
    }
}
