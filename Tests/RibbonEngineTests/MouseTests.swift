import CoreGraphics
import XCTest
import RibbonCore
@testable import RibbonEngine

final class MouseTests: XCTestCase {
    func testDragOntoAnotherColumnReorders() {
        let h = Harness().start([1, 2, 3], focused: 1)
        var dragged = h.applier.expected[1]!
        dragged.origin.x = 600
        h.windows.windows[1]?.frame = dragged
        h.input.leftDown = true
        h.windows.emit(.windowMoved(1, dragged))
        XCTAssertEqual(h.order, [[1], [2], [3]], "nothing happens mid-drag")
        h.input.leftDown = false
        h.input.mouse = CGPoint(x: 750, y: 300)
        h.input.mouseUpHandler?()
        XCTAssertEqual(h.order, [[2], [1], [3]])
    }

    func testDragResizeAdoptsWidthAndHeight() {
        let h = Harness().start([1, 2], focused: 1)
        h.manager.perform(.stackIntoRight)
        h.settle()
        var resized = h.applier.expected[2]!
        resized.size.width = 300
        h.windows.windows[2]?.frame = resized
        h.input.leftDown = true
        h.windows.emit(.windowResized(2, resized))
        h.input.leftDown = false
        h.input.mouseUpHandler?()
        XCTAssertEqual(h.strip.columns[0].widthFraction, 310.0 / 1010.0, accuracy: 1e-6)
        h.settle()
        var taller = h.applier.expected[1]!
        taller.size.height = 500
        h.windows.windows[1]?.frame = taller
        h.input.leftDown = true
        h.windows.emit(.windowResized(1, taller))
        h.input.leftDown = false
        h.input.mouseUpHandler?()
        let weights = h.strip.columns[0].heightWeights
        XCTAssertEqual(weights[1] / weights.reduce(0, +), 500.0 / 765.0, accuracy: 1e-3)
    }

    func testDragResizingTheEdgeBetweenTwoWindowsKeepsBothOnScreen() {
        let h = Harness().start([1, 2], focused: 1)
        var wider = h.applier.expected[1]!
        wider.size.width = 600
        h.windows.windows[1]?.frame = wider
        h.input.leftDown = true
        h.windows.emit(.windowResized(1, wider))
        h.input.leftDown = false
        h.input.mouseUpHandler?()
        XCTAssertEqual(h.applier.expected[1]?.width, 600)
        XCTAssertEqual(h.applier.expected[2]?.minX, 610)
        XCTAssertEqual(h.applier.expected[2]?.maxX, 1000, "the other window shrank instead of sliding off-screen")
    }

    func testDragToAnotherDisplay() {
        let h = Harness(displays: [Harness.mainDisplay, Harness.rightDisplay])
        h.windows.add(h.win(1, x: 0))
        h.windows.add(h.win(2, x: 100))
        h.windows.add(h.win(3, x: 1200))
        h.manager.start()
        h.settle()
        var dragged = h.applier.expected[1]!
        dragged.origin.x = 1300
        h.windows.windows[1]?.frame = dragged
        h.input.leftDown = true
        h.windows.emit(.windowMoved(1, dragged))
        h.input.leftDown = false
        h.input.mouse = CGPoint(x: 1800, y: 300)
        h.input.mouseUpHandler?()
        XCTAssertEqual(h.manager.world.strip(StripKey(displayUUID: "RIGHT", spaceID: 0)).allWindows, [3, 1])
        XCTAssertEqual(h.order, [[2]])
    }

    func testGestureScrollsAndSnaps() {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.gestures.handler?(.began)
        XCTAssertEqual(h.applier.cancelCount, 1)
        h.gestures.handler?(.changed(dx: 150))
        h.gestures.handler?(.changed(dx: 150))
        XCTAssertEqual(h.strip.viewportOffset, 300)
        XCTAssertEqual(h.applier.expected[2]?.minX, 205)
        h.gestures.handler?(.ended(velocity: 0))
        XCTAssertEqual(h.strip.viewportOffset, 505)
        XCTAssertEqual(h.windows.focusCalls.last, 2)
        h.gestures.handler?(.changed(dx: -400))
        h.gestures.handler?(.cancelled)
        XCTAssertEqual(h.strip.viewportOffset, 0)
    }

    func testFocusFollowsMouseNeverScrolls() {
        var settings = Harness.testSettings
        settings.behavior.focusFollowsMouse = true
        settings.layout.centreMode = .always
        settings.layout.defaultWidthFraction = 0.3
        let h = Harness(settings: settings).start([1, 2, 3], focused: 1)
        h.windows.emit(.windowFocused(1))
        let offset = h.strip.viewportOffset
        let target = h.applier.expected[2]!
        guard Harness.mainDisplay.frame.contains(target.center) else { return XCTFail("window 2 should be on screen") }
        h.input.mouseMovedHandler?(target.center)
        h.scheduler.advance(by: 0.2)
        XCTAssertEqual(h.windows.focusCalls.last, 2)
        h.windows.emit(.windowFocused(2))
        XCTAssertEqual(h.strip.viewportOffset, offset, "hover focus doesn't scroll")
    }

    func testDisabledDisplayIsLeftAlone() {
        var settings = Harness.testSettings
        settings.disabledDisplays = ["RIGHT"]
        let h = Harness(displays: [Harness.mainDisplay, Harness.rightDisplay], settings: settings)
        h.windows.add(h.win(1, x: 0))
        h.windows.add(h.win(2, x: 1200))
        h.manager.start()
        XCTAssertFalse(h.manager.world.isManaged(2))
        XCTAssertTrue(h.manager.world.isManaged(1))
        settings.disabledDisplays = []
        h.manager.updateSettings(settings)
        XCTAssertTrue(h.manager.world.isManaged(2))
        settings.disabledDisplays = ["MAIN"]
        h.manager.updateSettings(settings)
        XCTAssertFalse(h.manager.world.isManaged(1))
    }

    func testScreenRemovalMergesItsStrip() {
        let h = Harness(displays: [Harness.mainDisplay, Harness.rightDisplay])
        h.windows.add(h.win(1, x: 0))
        h.windows.add(h.win(2, x: 1200))
        h.manager.start()
        h.screens.list = [Harness.mainDisplay]
        h.screens.changeHandler?()
        XCTAssertEqual(h.order, [[1], [2]])
    }

    func testNativeTabsShareOneColumn() {
        let h = Harness().start([1], focused: 1)
        let frame = h.applier.expected[1]!
        var tab = h.win(9)
        tab.frame = frame
        h.windows.add(tab)
        h.windows.onScreenOverride = [9]
        h.windows.emit(.windowCreated(tab))
        XCTAssertEqual(h.order, [[1]], "checked after a short delay")
        h.scheduler.advance(by: 0.2)
        XCTAssertEqual(h.order, [[9]], "the new tab replaced the old one in place")
        h.windows.onScreenOverride = [1]
        h.windows.emit(.windowFocused(1))
        XCTAssertEqual(h.order, [[1]], "switching back to the first tab")
        h.windows.windows[1] = nil
        h.windows.onScreenOverride = [9]
        h.windows.emit(.windowDestroyed(1))
        XCTAssertEqual(h.order, [[9]], "closing a tab keeps the column")
    }

    func testSameFrameWindowThatIsOnScreenIsNotATab() {
        let h = Harness().start([1], focused: 1)
        var other = h.win(9)
        other.frame = h.applier.expected[1]!
        h.windows.add(other)
        h.windows.emit(.windowCreated(other))
        h.scheduler.advance(by: 0.2)
        XCTAssertEqual(h.order, [[1], [9]])
    }

    func testInactiveTabsFoundAtStartupAreGrouped() {
        let h = Harness()
        h.windows.add(h.win(1, x: 0))
        h.windows.add(h.win(2, x: 0))
        h.windows.onScreenOverride = [1]
        h.manager.start()
        XCTAssertEqual(h.order, [[1]])
        h.windows.onScreenOverride = [2]
        h.windows.emit(.windowFocused(2))
        XCTAssertEqual(h.order, [[2]])
    }
}
