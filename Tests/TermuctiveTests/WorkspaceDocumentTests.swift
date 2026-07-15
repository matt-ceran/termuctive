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
}
