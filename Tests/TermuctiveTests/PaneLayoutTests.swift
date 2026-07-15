import XCTest

@testable import Termuctive

final class PaneLayoutTests: XCTestCase {
    func testSplittingTargetsOnlyTheRequestedPane() throws {
        let first = TerminalPane(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            workingDirectory: "/first"
        )
        let second = TerminalPane(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            workingDirectory: "/second"
        )
        let root = PaneNode.terminal(first)

        let updated = try XCTUnwrap(
            root.splittingTerminal(
                withID: first.id,
                axis: .horizontal,
                newPane: second
            )
        )

        XCTAssertEqual(updated.terminalCount, 2)
        XCTAssertEqual(updated.terminal(withID: first.id), first)
        XCTAssertEqual(updated.terminal(withID: second.id), second)
        guard case .split(let split) = updated else {
            return XCTFail("Expected a split root.")
        }
        XCTAssertEqual(split.axis, .horizontal)
    }

    func testRemovingAPaneCollapsesItsParentSplit() throws {
        let first = TerminalPane(workingDirectory: "/first")
        let second = TerminalPane(workingDirectory: "/second")
        let root = try XCTUnwrap(
            PaneNode.terminal(first).splittingTerminal(
                withID: first.id,
                axis: .vertical,
                newPane: second
            )
        )

        let updated = try XCTUnwrap(root.removingTerminal(withID: second.id))

        XCTAssertEqual(updated, .terminal(first))
        XCTAssertEqual(updated.terminalCount, 1)
    }

    func testSplitRatioIsClamped() {
        let first = PaneNode.terminal(TerminalPane(workingDirectory: "/first"))
        let second = PaneNode.terminal(TerminalPane(workingDirectory: "/second"))
        let split = PaneSplit(axis: .horizontal, first: first, second: second)
        let root = PaneNode.split(split)

        let updated = root.settingRatio(forSplitID: split.id, to: 3)

        guard case .split(let result) = updated else {
            return XCTFail("Expected a split root.")
        }
        XCTAssertEqual(result.ratio, 0.9)
    }
}
