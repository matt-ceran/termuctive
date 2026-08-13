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
            ],
            lastSelectedSpaceID: space.id
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

    func testDocumentWithoutRememberedProjectSpaceStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pane = TerminalPane(workingDirectory: "/project")
        let space = TerminalSpace(name: "Terminal", layout: .terminal(pane))
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(space)]
        )
        let document = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: space.id
        )
        let fileURL = directory.appendingPathComponent("workspace.json")
        let persistence = WorkspaceFileStore(fileURL: fileURL)

        try persistence.save(document)

        let json = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(json.contains("lastSelectedSpaceID"))
        XCTAssertEqual(try persistence.load(), document)
    }

    func testDocumentWithoutSectionKindLoadsAsProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pane = TerminalPane(workingDirectory: "/project")
        let space = TerminalSpace(name: "Terminal", layout: .terminal(pane))
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(space)]
        )
        let document = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: space.id
        )
        let fileURL = directory.appendingPathComponent("workspace.json")
        let persistence = WorkspaceFileStore(fileURL: fileURL)
        try persistence.save(document)
        let savedData = try Data(contentsOf: fileURL)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: savedData) as? [String: Any]
        )
        var projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        projects[0].removeValue(forKey: "kind")
        json["projects"] = projects
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL)

        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded.projects.first?.kind, .project)
        XCTAssertEqual(loaded, document)
    }

    func testDocumentRoundTripPreservesSelectedNestedNote() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let note = ProjectNote(name: "Learning")
        let folder = WorkspaceFolder(name: "Docs", children: [.note(note)])
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.folder(folder)],
            lastSelectedItemID: note.id
        )
        let document = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedItemID: note.id
        )
        let persistence = WorkspaceFileStore(
            fileURL: directory.appendingPathComponent("workspace.json")
        )

        try persistence.save(document)
        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded.selectedNote, note)
        XCTAssertNil(loaded.selectedSpace)
    }

    func testSchemaOneWorkspaceMigratesItsLegacySpaceSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pane = TerminalPane(workingDirectory: "/project")
        let space = TerminalSpace(name: "Terminal", layout: .terminal(pane))
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.space(space)],
            lastSelectedSpaceID: space.id
        )
        let document = WorkspaceDocument(
            projects: [project],
            selectedProjectID: project.id,
            selectedSpaceID: space.id
        )
        let fileURL = directory.appendingPathComponent("workspace.json")
        let persistence = WorkspaceFileStore(fileURL: fileURL)
        try persistence.save(document)
        let data = try Data(contentsOf: fileURL)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json["schemaVersion"] = 1
        json.removeValue(forKey: "selectedItemID")
        var projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        projects[0].removeValue(forKey: "lastSelectedItemID")
        json["projects"] = projects
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL)

        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded.schemaVersion, WorkspaceDocument.currentSchemaVersion)
        XCTAssertEqual(loaded.selectedItemID, space.id)
        XCTAssertEqual(loaded.projects[0].lastSelectedItemID, space.id)
        XCTAssertEqual(loaded.selectedSpace, space)
    }
}
