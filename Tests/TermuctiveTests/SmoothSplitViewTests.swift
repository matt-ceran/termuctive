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

    func testRepeatedModelRatioDoesNotScheduleAnotherLayout() {
        let splitView = makeSplitView(axis: .horizontal)
        splitView.setRatio(0.65)
        splitView.layoutSubtreeIfNeeded()
        splitView.needsLayout = false

        splitView.setRatio(0.65)

        XCTAssertFalse(splitView.needsLayout)
        XCTAssertEqual(splitView.ratio, 0.65, accuracy: 0.01)
    }

    func testOrdinaryBoundsChangesPreserveTheRequestedRatio() {
        let splitView = makeSplitView(axis: .horizontal)
        splitView.setRatio(0.63)
        splitView.layoutSubtreeIfNeeded()

        for width in stride(from: 980, through: 520, by: -20) {
            splitView.setFrameSize(
                NSSize(width: CGFloat(width), height: 700)
            )
            splitView.layoutSubtreeIfNeeded()
            XCTAssertEqual(splitView.ratio, 0.63, accuracy: 0.01)
        }
    }

    func testResizeLeaseEndsForAReparentedTerminal() {
        let splitView = makeSplitView(axis: .horizontal)
        let terminal = TermuctiveTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        splitView.arrangedSubviews[0].addSubview(terminal)

        splitView.beginTerminalResizeForTesting()
        terminal.removeFromSuperview()
        splitView.endTerminalResizeForTesting()

        switch terminal.metalBufferingMode {
        case .perRowPersistent:
            break
        case .perFrameAggregated:
            XCTFail("Reparenting must not strand the captured resize lease.")
        }
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
