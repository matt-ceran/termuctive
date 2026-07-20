import AppKit
import XCTest

@testable import Termuctive

@MainActor
final class SmoothSplitViewTests: XCTestCase {
    func testSideBySideSplitAppliesRequestedRatio() {
        let splitView = makeSplitView(axis: .horizontal)

        splitView.setRatio(0.7)
        splitView.layoutSubtreeIfNeeded()

        XCTAssertEqual(splitView.ratio, 0.7, accuracy: 0.01)
    }

    func testStackedSplitAppliesRequestedRatio() {
        let splitView = makeSplitView(axis: .vertical)

        splitView.setRatio(0.35)
        splitView.layoutSubtreeIfNeeded()

        XCTAssertEqual(splitView.ratio, 0.35, accuracy: 0.01)
    }

    func testDividerPositionIsClampedToTenPercent() {
        let splitView = makeSplitView(axis: .horizontal)
        splitView.setRatio(0.5)
        splitView.layoutSubtreeIfNeeded()

        splitView.setPosition(0, ofDividerAt: 0)

        XCTAssertEqual(splitView.ratio, 0.1, accuracy: 0.01)
    }

    func testSidebarActionLookupDoesNotRecurseThroughSplitViewDelegate() {
        let splitView = makeSplitView(axis: .horizontal)

        guard let delegate = splitView.delegate else {
            return XCTFail("Expected SmoothSplitView to retain a delegate.")
        }
        XCTAssertFalse((delegate as AnyObject) === splitView)
        XCTAssertFalse(splitView.responds(to: NSSelectorFromString("toggleSidebar:")))
    }

    private func makeSplitView(axis: PaneAxis) -> SmoothSplitView {
        let splitView = SmoothSplitView(axis: axis)
        splitView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        splitView.addArrangedSubview(NSView(frame: .zero))
        splitView.addArrangedSubview(NSView(frame: .zero))
        splitView.adjustSubviews()
        return splitView
    }
}
