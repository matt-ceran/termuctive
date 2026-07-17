import Foundation
import XCTest

@testable import Termuctive

final class TerminalLocalCommandTests: XCTestCase {
    func testMovePDFCommandsAreInterceptedBeforeReturnReachesTheProcess() {
        let commands: [(String, PDFPanePlacement)] = [
            ("/movepdf", .automatic),
            ("/movepdfleft", .left),
            ("/movepdfright", .right),
        ]

        for (input, placement) in commands {
            var interceptor = TerminalLocalCommandInterceptor()
            let decision = interceptor.process(Array("\(input)\r".utf8)[...])

            XCTAssertEqual(decision.bytesToForward, Array(input.utf8))
            XCTAssertTrue(decision.shouldClearCurrentLine)
            XCTAssertEqual(decision.command, .moveRecentPDF(placement))
        }
    }

    func testUnknownSlashCommandPassesThroughUnchanged() {
        var interceptor = TerminalLocalCommandInterceptor()
        let bytes = Array("/status\r".utf8)

        let decision = interceptor.process(bytes[...])

        XCTAssertEqual(decision.bytesToForward, bytes)
        XCTAssertFalse(decision.shouldClearCurrentLine)
        XCTAssertNil(decision.command)
    }

    func testBackspaceUpdatesTheTrackedCommandLine() {
        var interceptor = TerminalLocalCommandInterceptor()
        _ = interceptor.process(Array("/movepdfrighx".utf8)[...])
        _ = interceptor.process([0x7F][...])

        let decision = interceptor.process(Array("t\r".utf8)[...])

        XCTAssertEqual(decision.bytesToForward, [UInt8(ascii: "t")])
        XCTAssertTrue(decision.shouldClearCurrentLine)
        XCTAssertEqual(decision.command, .moveRecentPDF(.right))
    }
}
