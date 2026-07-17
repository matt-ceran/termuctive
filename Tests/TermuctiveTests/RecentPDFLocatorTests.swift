import Foundation
import XCTest

@testable import Termuctive

final class RecentPDFLocatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testNewestPDFModifiedDuringTheSessionWins() throws {
        let sessionStart = Date(timeIntervalSince1970: 1_000)
        let olderPDF = temporaryDirectory.appendingPathComponent("older.pdf")
        let newestPDF = temporaryDirectory.appendingPathComponent("newest.PDF")
        let newerText = temporaryDirectory.appendingPathComponent("ignore.txt")
        try Data("older".utf8).write(to: olderPDF)
        try Data("newest".utf8).write(to: newestPDF)
        try Data("not a pdf".utf8).write(to: newerText)
        try setModificationDate(sessionStart.addingTimeInterval(10), for: olderPDF)
        try setModificationDate(sessionStart.addingTimeInterval(20), for: newestPDF)
        try setModificationDate(sessionStart.addingTimeInterval(30), for: newerText)

        let result = RecentPDFLocator.mostRecentPDF(
            in: [temporaryDirectory],
            modifiedAfter: sessionStart
        )

        XCTAssertEqual(result, newestPDF.standardizedFileURL)
    }

    func testPDFsFromBeforeTheTerminalSessionAreIgnored() throws {
        let sessionStart = Date(timeIntervalSince1970: 2_000)
        let stalePDF = temporaryDirectory.appendingPathComponent("stale.pdf")
        try Data("stale".utf8).write(to: stalePDF)
        try setModificationDate(sessionStart.addingTimeInterval(-10), for: stalePDF)

        let result = RecentPDFLocator.mostRecentPDF(
            in: [temporaryDirectory],
            modifiedAfter: sessionStart
        )

        XCTAssertNil(result)
    }

    func testTerminalOutputTrackerResolvesPrintedPDFPath() throws {
        let pdf = temporaryDirectory.appendingPathComponent("Codex Report.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let encodedPath = pdf.path.replacingOccurrences(of: " ", with: "%20")
        var tracker = TerminalOutputPDFTracker()

        let matches = tracker.consume(
            Array("Created [report](\(encodedPath))\n".utf8)[...],
            workingDirectory: temporaryDirectory.path
        )

        XCTAssertEqual(matches, [pdf.standardizedFileURL])
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}
