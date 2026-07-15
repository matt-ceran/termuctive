import XCTest

@testable import Termuctive

final class WorkspaceFileStoreTests: XCTestCase {
    func testDocumentRoundTripPreservesNestedLayout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let first = TerminalPane(workingDirectory: "/project")
        let second = TerminalPane(workingDirectory: "/project/tests")
        let layout = try XCTUnwrap(
            PaneNode.terminal(first).splittingTerminal(
                withID: first.id,
                axis: .horizontal,
                newPane: second
            )
        )
        let space = TerminalSpace(name: "Development", layout: layout)
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [
                .folder(
                    WorkspaceFolder(
                        name: "Work",
                        children: [.space(space)]
                    )
                )
            ]
        )
        let document = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: space.id
        )
        let persistence = WorkspaceFileStore(
            fileURL: directory.appendingPathComponent("workspace.json")
        )

        try persistence.save(document)
        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded, document)
    }

    func testMissingFileLoadsAsNoDocument() throws {
        let persistence = WorkspaceFileStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("workspace.json")
        )

        XCTAssertNil(try persistence.load())
    }
}
