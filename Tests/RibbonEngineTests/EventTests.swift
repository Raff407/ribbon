import CoreGraphics
import XCTest
import RibbonCore
@testable import RibbonEngine

final class EventTests: XCTestCase {
    func testNewFocusedWindowOpensAfterFocused() {
        let h = Harness().start([1, 2], focused: 1)
        h.windows.add(h.win(5, x: 50))
        h.windows.focused = 5
        h.windows.emit(.windowCreated(h.win(5, x: 50)))
        XCTAssertEqual(h.order, [[1], [5], [2]])
        XCTAssertEqual(h.strip.focusedWindow, 5)
    }

    func testBackgroundWindowDoesNotStealFocusOrScroll() {
        let h = Harness().start([1, 2, 3], focused: 1)
        let offset = h.strip.viewportOffset
        h.windows.add(h.win(6))
        h.windows.emit(.windowCreated(h.win(6)))
        XCTAssertEqual(h.order, [[1], [6], [2], [3]])
        XCTAssertEqual(h.strip.focusedWindow, 1)
        XCTAssertEqual(h.strip.viewportOffset, offset)
        XCTAssertTrue(h.windows.focusCalls.isEmpty)
    }

    func testNewWindowsAtEndWhenConfigured() {
        var settings = Harness.testSettings
        settings.behavior.newWindowPosition = .end
        let h = Harness(settings: settings).start([1, 2], focused: 1)
        h.windows.emit(.windowCreated(h.win(7)))
        XCTAssertEqual(h.order, [[1], [2], [7]])
    }

    func testClosingFocusedWindowFocusesLeftNeighbour() {
        let h = Harness().start([1, 2, 3], focused: 3)
        h.windows.windows[3] = nil
        h.windows.emit(.windowDestroyed(3))
        XCTAssertEqual(h.order, [[1], [2]])
        h.scheduler.advance(by: 0.06)
        XCTAssertEqual(h.windows.focusCalls.last, 2)
        XCTAssertNil(h.applier.expected[3])
    }

    func testClosingUnmanagedWindowIsHarmless() {
        let h = Harness().start([1])
        h.windows.emit(.windowDestroyed(42))
        XCTAssertEqual(h.order, [[1]])
    }

    func testExternalFocusRevealsWindow() {
        let h = Harness().start([1, 2, 3], focused: 1)
        XCTAssertEqual(h.strip.viewportOffset, 0)
        h.windows.emit(.windowFocused(3))
        XCTAssertEqual(h.strip.focusedWindow, 3)
        XCTAssertEqual(h.strip.viewportOffset, 505)
        XCTAssertEqual(h.applier.expected[3]?.minX, 505)
    }

    func testStaleFocusEventsIgnoredRightAfterRibbonFocuses() {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.manager.perform(.focus(.right))
        h.windows.emit(.windowFocused(1))
        XCTAssertEqual(h.strip.focusedWindow, 2, "late event for the old window is ignored")
        h.scheduler.advance(by: 0.5)
        h.windows.emit(.windowFocused(1))
        XCTAssertEqual(h.strip.focusedWindow, 1)
    }

    func testFocusOfUnknownWindowAdoptsIt() {
        let h = Harness().start([1], focused: 1)
        h.windows.add(h.win(8, x: 900))
        h.windows.emit(.windowFocused(8))
        XCTAssertEqual(h.order, [[1], [8]])
        XCTAssertEqual(h.strip.focusedWindow, 8)
    }

    func testMinimizeAndRestoreKeepsPosition() {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.windows.emit(.windowMinimized(2))
        XCTAssertEqual(h.order, [[1], [3]])
        h.windows.emit(.windowDeminimized(2))
        XCTAssertEqual(h.order, [[1], [2], [3]])
        XCTAssertEqual(h.strip.focusedWindow, 2)
    }

    func testFullscreenLeavesAndRejoins() {
        let h = Harness().start([1, 2], focused: 1)
        h.windows.emit(.windowFullscreenChanged(1, true))
        XCTAssertEqual(h.order, [[2]])
        h.windows.emit(.windowFullscreenChanged(1, false))
        XCTAssertEqual(h.order, [[2]], "waits for the exit animation")
        h.scheduler.advance(by: 0.6)
        XCTAssertEqual(h.order, [[1], [2]])
    }

    func testHideAndShowApp() {
        let h = Harness()
        h.windows.add(h.win(1, x: 0, pid: 1))
        h.windows.add(h.win(2, x: 100, pid: 1))
        h.windows.add(h.win(3, x: 200, pid: 2))
        h.manager.start()
        h.windows.emit(.appHidden(1))
        XCTAssertEqual(h.order, [[3]])
        h.windows.emit(.appShown(1))
        XCTAssertEqual(h.order, [[1], [2], [3]])
    }

    func testAppTerminationRemovesItsWindows() {
        let h = Harness()
        h.windows.add(h.win(1, x: 0, pid: 1))
        h.windows.add(h.win(2, x: 100, pid: 2))
        h.manager.start()
        h.windows.emit(.appTerminated(1))
        XCTAssertEqual(h.order, [[2]])
        h.windows.emit(.appTerminated(99))
        XCTAssertEqual(h.order, [[2]])
    }

    func testTitleChangeUpdatesTabBars() {
        let h = Harness().start([1, 2], focused: 1)
        h.manager.perform(.stackIntoRight)
        h.manager.perform(.toggleTabbed)
        XCTAssertEqual(h.overlays.tabBars.count, 1)
        h.windows.emit(.windowTitleChanged(1, "Renamed"))
        XCTAssertEqual(h.overlays.tabBars.first?.tabs.map(\.title), ["W2", "Renamed"])
    }

    func testOwnMovesAreIgnoredAndAppMovesSnapBack() {
        let h = Harness().start([1, 2], focused: 1)
        let count = h.applier.applied.count
        h.windows.emit(.windowMoved(1, h.applier.expected[1]!))
        h.settle()
        XCTAssertEqual(h.applier.applied.count, count, "Ribbon's own move")
        var moved = h.applier.expected[1]!
        moved.origin.x += 50
        h.windows.windows[1]?.frame = moved
        h.windows.emit(.windowMoved(1, moved))
        h.scheduler.advance(by: 0.3)
        XCTAssertEqual(h.applier.lastTransitions[1]?.target, h.applier.expected[1], "snapped back")
        XCTAssertGreaterThan(h.applier.applied.count, count)
    }

    func testAppEnforcedWidthIsAdoptedAtMostEveryTwoSeconds() {
        let h = Harness().start([1, 2], focused: 1)
        var frame = h.applier.expected[2]!
        frame.size.width = 600
        h.windows.windows[2]?.frame = frame
        h.windows.emit(.windowResized(2, frame))
        h.scheduler.advance(by: 0.3)
        XCTAssertEqual(h.strip.columns[1].widthFraction, 610.0 / 1010.0, accuracy: 1e-6)
        frame.size.width = 800
        h.windows.windows[2]?.frame = frame
        h.windows.emit(.windowResized(2, frame))
        h.scheduler.advance(by: 0.3)
        XCTAssertEqual(h.strip.columns[1].widthFraction, 610.0 / 1010.0, accuracy: 1e-6, "rate limited")
    }

    func testSpaceChangeLaysOutTheNewSpace() {
        let h = Harness()
        h.spaces.current["MAIN"] = 1
        h.windows.add(h.win(1))
        h.spaces.windowSpaces[1] = 1
        h.manager.start()
        XCTAssertEqual(h.order, [[1]])
        h.spaces.current["MAIN"] = 2
        h.windows.hiddenFromAX = [1]
        h.windows.add(h.win(2))
        h.spaces.windowSpaces[2] = 2
        h.windows.emit(.spaceChanged)
        h.scheduler.advance(by: 0.3)
        XCTAssertEqual(h.order, [[2]])
        XCTAssertEqual(h.manager.world.strip(StripKey(displayUUID: "MAIN", spaceID: 1)).allWindows, [1], "other Space keeps its strip")
    }

    func testReconcileKeepsOtherSpaceWindowsAndNeverPrunesOnEmptyList() {
        let h = Harness().start([1, 2, 3])
        h.windows.hiddenFromAX = [2]
        h.windows.windows[3] = nil
        h.windows.emit(.appActivated(10))
        h.scheduler.advance(by: 0.4)
        XCTAssertEqual(h.order, [[1], [2]])
        h.windows.existingOverride = []
        h.windows.emit(.appActivated(10))
        h.scheduler.advance(by: 0.4)
        XCTAssertEqual(h.order, [[1], [2]])
    }

    func testWakeRelaysOutEverything() {
        let h = Harness().start([1])
        let count = h.applier.applied.count
        h.windows.emit(.systemWoke)
        h.scheduler.advance(by: 1.1)
        XCTAssertGreaterThan(h.applier.applied.count, count)
    }
}
