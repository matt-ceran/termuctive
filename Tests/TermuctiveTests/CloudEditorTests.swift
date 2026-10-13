import Foundation
import XCTest

@testable import Termuctive

final class RemoteEditorFileSystemTests: XCTestCase {
    func testNavigatorTreesSortFoldersFirstAndNestChildren() {
        let root = URL(fileURLWithPath: "/srv/project", isDirectory: true)
        let tree = EditorFileTreeSnapshot.from(
            entries: [
                ("zeta.txt", false), ("src", true), ("src/b.swift", false), ("src/a.swift", false),
                ("Alpha.md", false), ("docs", true),
            ],
            rootURL: root,
            isTruncated: false
        )

        XCTAssertEqual(tree.nodes.map(\.name), ["docs", "src", "Alpha.md", "zeta.txt"])
        XCTAssertEqual(tree.nodes[1].children.map(\.name), ["a.swift", "b.swift"])
        XCTAssertEqual(tree.nodes[1].children[0].url.path, "/srv/project/src/a.swift")
    }

    func testReadsDecodeLikeLocalFilesAndSavesDetectConflicts() async throws {
        let original = Data("one\r\ntwo\r\n".utf8)
        let runner = RecordingCloudRunner { command in
            let line = command.remoteCommandLine
            let body: String
            if line.contains(" fs read ") {
                body =
                    #"{"exists": true, "isDirectory": false, "size": 10, "digest": "d1", "content": ""#
                    + original.base64EncodedString() + #""}"#
            } else if line.contains("--expect stale") {
                body =
                    #"{"conflict": true, "current": {"exists": true, "content": ""#
                    + Data("theirs\n".utf8).base64EncodedString() + #""}}"#
            } else {
                body = #"{"written": true, "digest": "d2"}"#
            }
            return ProcessResult(status: 0, output: Data(body.utf8), error: Data(), timedOut: false)
        }
        let files = RemoteEditorFileSystem(runner: runner, alias: "tmc-test")
        let url = URL(fileURLWithPath: "/srv/project/notes.txt")

        let snapshot = try await files.read(url)
        XCTAssertEqual(snapshot.text, "one\ntwo\n")
        XCTAssertEqual(snapshot.lineEnding, .carriageReturnLineFeed)
        XCTAssertEqual(snapshot.contentDigest, EditorDiskIO.digest(of: original))

        let saved = try await files.write(
            text: "one\nthree\n",
            to: url,
            encoding: .utf8,
            lineEnding: .carriageReturnLineFeed,
            expectedSnapshot: snapshot
        )
        XCTAssertEqual(saved.text, "one\nthree\n")
        let write = try XCTUnwrap(runner.commands.last)
        XCTAssertEqual(write.input, Data("one\r\nthree\r\n".utf8))
        XCTAssertTrue(write.remoteCommandLine.hasSuffix("--expect \(snapshot.contentDigest ?? "")"))

        let stale = EditorDiskSnapshot(
            text: "one\n",
            encoding: .utf8,
            lineEnding: .lineFeed,
            contentDigest: "stale"
        )
        do {
            _ = try await files.write(
                text: "mine\n",
                to: url,
                encoding: .utf8,
                lineEnding: .lineFeed,
                expectedSnapshot: stale
            )
            XCTFail("A stale save must be refused")
        } catch EditorDocumentError.changedOnDisk(let current) {
            XCTAssertEqual(current?.text, "theirs\n")
        }
    }

    func testPDFPathsPrintedOnAServerAreDetectedWithoutALocalFile() {
        let output = "Rendered the lesson.\n/Users/m/project/tmp/pdfs/lesson.pdf\n"
        XCTAssertEqual(
            TerminalOutputPDFTracker.detectedURLs(
                in: output,
                workingDirectory: "/Users/m/project",
                requiresLocalFile: false
            ).map(\.path),
            ["/Users/m/project/tmp/pdfs/lesson.pdf"]
        )
        XCTAssertTrue(
            TerminalOutputPDFTracker.detectedURLs(
                in: output,
                workingDirectory: "/Users/m/project"
            ).isEmpty
        )
    }
}
