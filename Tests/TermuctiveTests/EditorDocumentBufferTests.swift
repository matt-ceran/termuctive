import Foundation
import XCTest

@testable import Termuctive

@MainActor
final class EditorDocumentBufferTests: XCTestCase {
    func testEditingAndSavingPreservesLineEndingsAndPermissions() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\r\necho before\r\n".utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fileURL.path
        )

        let buffer = try await EditorDocumentBuffer.open(url: fileURL)
        XCTAssertEqual(buffer.text, "#!/bin/sh\necho before\n")
        XCTAssertEqual(buffer.lineEndingTitle, "CRLF")
        XCTAssertFalse(buffer.isDirty)

        buffer.updateText("#!/bin/sh\necho after\n")
        XCTAssertTrue(buffer.isDirty)
        try await buffer.save()

        XCTAssertEqual(
            String(decoding: try Data(contentsOf: fileURL), as: UTF8.self),
            "#!/bin/sh\r\necho after\r\n"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o755)
        XCTAssertFalse(buffer.isDirty)
    }

    func testCleanBufferReloadsAnExternalChange() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)
        let buffer = try await EditorDocumentBuffer.open(url: fileURL)

        try Data("let value = 2\n".utf8).write(to: fileURL, options: .atomic)
        await buffer.refreshFromDisk()

        XCTAssertEqual(buffer.text, "let value = 2\n")
        XCTAssertEqual(buffer.statusMessage, "Updated from disk")
        XCTAssertNil(buffer.externalChange)
        XCTAssertFalse(buffer.isDirty)
    }

    func testRecreatedCleanFileClearsADeletionConflict() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)
        let buffer = try await EditorDocumentBuffer.open(url: fileURL)

        try FileManager.default.removeItem(at: fileURL)
        await buffer.refreshFromDisk()
        XCTAssertEqual(buffer.externalChange, .deleted)

        try Data("let value = 1\n".utf8).write(to: fileURL)
        await buffer.refreshFromDisk()

        XCTAssertNil(buffer.externalChange)
        XCTAssertNil(buffer.errorMessage)
        XCTAssertFalse(buffer.isDirty)
    }

    func testDirtyBufferRequiresConflictResolutionBeforeOverwrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)
        let buffer = try await EditorDocumentBuffer.open(url: fileURL)

        buffer.updateText("let value = 3\n")
        try Data("let value = 2\n".utf8).write(to: fileURL, options: .atomic)
        await buffer.refreshFromDisk()

        guard case .modified(let diskSnapshot) = buffer.externalChange else {
            XCTFail("Expected an external modification conflict.")
            return
        }
        XCTAssertEqual(diskSnapshot.text, "let value = 2\n")
        XCTAssertFalse(buffer.canSave)

        do {
            try await buffer.save()
            XCTFail("Saving should be blocked while the conflict is unresolved.")
        } catch EditorDocumentError.changedOnDisk {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: fileURL), as: UTF8.self),
            "let value = 2\n"
        )

        buffer.keepLocalVersion()
        XCTAssertTrue(buffer.canSave)
        try await buffer.save()
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: fileURL), as: UTF8.self),
            "let value = 3\n"
        )
    }

    func testSaveStartedDuringAnotherSavePersistsTheNewestEdit() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)
        let buffer = try await EditorDocumentBuffer.open(url: fileURL)
        let firstText = String(repeating: "a", count: 2_000_000) + "\n"
        let newestText = String(repeating: "b", count: 2_000_000) + "\n"

        buffer.updateText(firstText)
        let firstSave = Task {
            try await buffer.save()
        }
        for _ in 0..<1_000 {
            if buffer.isSaving {
                break
            }
            await Task.yield()
        }
        guard buffer.isSaving else {
            try await firstSave.value
            XCTFail("The first save completed before the overlap could be exercised.")
            return
        }

        buffer.updateText(newestText)
        try await buffer.save()
        try await firstSave.value

        XCTAssertEqual(
            String(decoding: try Data(contentsOf: fileURL), as: UTF8.self),
            newestText
        )
        XCTAssertEqual(buffer.text, newestText)
        XCTAssertFalse(buffer.hasUncommittedChanges)
    }

    func testBinaryFileIsRejectedWithoutCreatingAnEditorBuffer() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("image.bin")
        try Data([0x01, 0x00, 0x02]).write(to: fileURL)

        do {
            _ = try await EditorDocumentBuffer.open(url: fileURL)
            XCTFail("Binary data should not be opened as source text.")
        } catch EditorDocumentError.binaryFile {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "termuctive-editor-buffer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
