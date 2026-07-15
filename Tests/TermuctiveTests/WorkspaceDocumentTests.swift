import XCTest

@testable import Termuctive

final class WorkspaceDocumentTests: XCTestCase {
    func testNestedSpaceCanBeUpdatedWithoutChangingItsIdentity() throws {
        let pane = TerminalPane(workingDirectory: "/project")
        let space = TerminalSpace(
            name: "Development",
            layout: .terminal(pane)
        )
        let folder = WorkspaceFolder(
            name: "Work",
            children: [.space(space)]
        )
        var project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.folder(folder)]
        )

        let changed = project.updateSpace(withID: space.id) { item in
            item.name = "Renamed"
        }

        XCTAssertTrue(changed)
        let updated = try XCTUnwrap(project.space(withID: space.id))
        XCTAssertEqual(updated.id, space.id)
        XCTAssertEqual(updated.name, "Renamed")
    }

    func testNestedTerminalCanBeUpdatedAcrossTheDocument() throws {
        let pane = TerminalPane(
            title: "zsh",
            workingDirectory: "/project"
        )
        let space = TerminalSpace(
            name: "Development",
            layout: .terminal(pane)
        )
        let folder = WorkspaceFolder(
            name: "Services",
            children: [.space(space)]
        )
        let project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.folder(folder)]
        )
        var document = WorkspaceDocument(projects: [project])

        let changed = document.updateTerminal(
            withID: pane.id,
            title: nil,
            workingDirectory: "/project/api"
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(document.terminalIDs, [pane.id])
        let updated = try XCTUnwrap(document.terminal(withID: pane.id))
        XCTAssertEqual(updated.title, "zsh")
        XCTAssertEqual(updated.workingDirectory, "/project/api")
    }

    func testNestedItemsCanBeRenamedAndRemoved() throws {
        let pane = TerminalPane(workingDirectory: "/project")
        let space = TerminalSpace(name: "Development", layout: .terminal(pane))
        let nestedFolder = WorkspaceFolder(
            name: "Nested",
            children: [.space(space)]
        )
        let rootFolder = WorkspaceFolder(
            name: "Root",
            children: [.folder(nestedFolder)]
        )
        var project = TerminalProject(
            name: "Project",
            rootDirectory: "/project",
            items: [.folder(rootFolder)]
        )

        XCTAssertTrue(project.renameItem(withID: space.id, to: "Server"))
        XCTAssertEqual(project.space(withID: space.id)?.name, "Server")
        XCTAssertFalse(project.renameItem(withID: space.id, to: "Server"))

        let removed = try XCTUnwrap(project.removeItem(withID: nestedFolder.id))

        XCTAssertEqual(removed.terminalIDs, [pane.id])
        XCTAssertFalse(project.folderIDs.contains(nestedFolder.id))
        XCTAssertTrue(project.folderIDs.contains(rootFolder.id))
        XCTAssertTrue(project.terminalIDs.isEmpty)
    }
}
