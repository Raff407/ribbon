import CoreGraphics
import XCTest
import RibbonCore
@testable import RibbonEngine

/// Windows that won't take their column's size, and windows that don't fit on screen.
final class ArrangementTests: XCTestCase {
    /// Columns of 0.5, 0.25 and 0.5 on the 1000pt test display (495, 242.5, 495 wide).
    private func harness() -> Harness {
        let h = Harness().start([1, 2, 3], focused: 1)
        let widths = [0.5, 0.25, 0.5]
        let columns = h.strip.columns.enumerated().map { i, column in
            Column(windows: column.windows, widthFraction: widths[i])
        }
        h.manager.world = h.manager.world.setting(Strip(columns: columns, focusedColumnIndex: 0, viewportOffset: 0), for: h.key)
        h.manager.relayout(animated: false, force: true)
        return h
    }

    private func onScreen(_ frame: CGRect?) -> Bool {
        guard let frame else { return false }
        return frame.intersectionArea(with: Harness.mainDisplay.frame) >= frame.width * frame.height / 2
    }

    func testWindowCutOffByTheEdgeIsParked() {
        let h = harness()
        XCTAssertTrue(onScreen(h.applier.expected[1]))
        XCTAssertTrue(onScreen(h.applier.expected[2]))
        XCTAssertFalse(onScreen(h.applier.expected[3]), "the third window doesn't fit, so it's parked")
    }

    func testRefusedWidthBecomesTheColumnWidth() throws {
        let h = harness()
        let expected = try XCTUnwrap(h.applier.expected[2])
        // The app keeps a 400pt minimum instead of 242.5.
        h.windows.emit(.windowRefusedSize(2, CGRect(x: expected.minX, y: expected.minY, width: 400, height: expected.height)))
        XCTAssertEqual(h.strip.columns[1].widthFraction, 410.0 / 1010.0, accuracy: 0.0001)
        let two = try XCTUnwrap(h.applier.expected[2])
        XCTAssertEqual(two.width, 400)
        let one = try XCTUnwrap(h.applier.expected[1])
        XCTAssertFalse(one.intersects(two.insetBy(dx: 0.5, dy: 0.5)))
        XCTAssertFalse(onScreen(h.applier.expected[3]))
    }

    func testRefusedWidthDoesNotLeaveTheWindowAloneWithAGap() throws {
        let h = harness()
        h.manager.perform(.focus(.right))
        h.manager.perform(.focus(.right))
        XCTAssertFalse(onScreen(h.applier.expected[1]), "window 1 makes room for window 3")
        h.manager.perform(.focus(.left))
        let expected = try XCTUnwrap(h.applier.expected[2])
        h.windows.emit(.windowRefusedSize(2, CGRect(x: expected.minX, y: expected.minY, width: 480, height: expected.height)))
        // Window 3 no longer fits beside the wider window 2, so the strip scrolls until a
        // whole neighbour does (495 + 10 + 480 fits in 1000).
        XCTAssertTrue(onScreen(h.applier.expected[2]))
        XCTAssertEqual([1, 2, 3].filter { onScreen(h.applier.expected[$0]) }.count, 2)
    }

    func testRefusedWidthIsAdoptedEvenWhileOtherWindowsAnimate() throws {
        let h = harness()
        h.applier.animating = true
        let expected = try XCTUnwrap(h.applier.expected[2])
        h.windows.emit(.windowRefusedSize(2, CGRect(x: expected.minX, y: expected.minY, width: 400, height: expected.height)))
        XCTAssertEqual(h.strip.columns[1].widthFraction, 410.0 / 1010.0, accuracy: 0.0001)
    }

    func testRefusedSizeOfParkedWindowIsIgnored() {
        let h = harness()
        h.windows.emit(.windowRefusedSize(3, CGRect(x: 999, y: 799, width: 300, height: 700)))
        XCTAssertEqual(h.strip.columns[2].widthFraction, 0.5)
    }

    func testRefusedSizeMatchingTheColumnChangesNothing() throws {
        let h = harness()
        let count = h.applier.applied.count
        let expected = try XCTUnwrap(h.applier.expected[1])
        h.windows.emit(.windowRefusedSize(1, expected.insetBy(dx: 1, dy: 0)))
        XCTAssertEqual(h.strip.columns[0].widthFraction, 0.5)
        XCTAssertEqual(h.applier.applied.count, count)
    }

    func testAppThatKeepsChangingItsMindIsOnlyFollowedAFewTimes() throws {
        let h = harness()
        for width in [300.0, 320, 340, 360, 380] {
            let expected = try XCTUnwrap(h.applier.expected[2])
            h.windows.emit(.windowRefusedSize(2, CGRect(x: expected.minX, y: expected.minY, width: width, height: expected.height)))
        }
        XCTAssertEqual(h.strip.columns[1].widthFraction, 350.0 / 1010.0, accuracy: 0.0001, "the third refusal is the last one adopted")
        h.scheduler.advance(by: 2.1)
        let expected = try XCTUnwrap(h.applier.expected[2])
        h.windows.emit(.windowRefusedSize(2, CGRect(x: expected.minX, y: expected.minY, width: 380, height: expected.height)))
        XCTAssertEqual(h.strip.columns[1].widthFraction, 390.0 / 1010.0, accuracy: 0.0001)
    }

    func testSwipeShowsCutOffWindowsUntilItSnaps() throws {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.manager.handleGesture(.began)
        h.manager.handleGesture(.changed(dx: 200))
        let mid = try XCTUnwrap(h.applier.expected[3])
        XCTAssertEqual(mid.minX, 810, "slides in with the fingers instead of popping in at the end")
        h.manager.handleGesture(.ended(velocity: 0))
        XCTAssertEqual(h.strip.viewportOffset, 0)
        XCTAssertFalse(onScreen(h.applier.expected[3]), "parked again once the swipe settles")
    }
}
