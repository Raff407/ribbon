import CoreGraphics
import XCTest
import RibbonCore
@testable import RibbonEngine

final class CommandTests: XCTestCase {
    func testFocusCommandsFocusAndScroll() {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.windows.focusCalls, [2])
        XCTAssertEqual(h.strip.viewportOffset, 0)
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.windows.focusCalls, [2, 3])
        XCTAssertEqual(h.strip.viewportOffset, 505)
        XCTAssertEqual(h.applier.expected[3]?.minX, 505)
        XCTAssertEqual(h.applier.expected[1]?.maxX, 1, "first column parked off the left edge")
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.windows.focusCalls, [2, 3, 1], "loops back to the first window")
        XCTAssertEqual(h.strip.viewportOffset, 0, "and scrolls back to it")
    }

    func testLoopAroundSlidesForwardInsteadOfRewinding() {
        let h = Harness().start([1, 2, 3, 4], focused: 1)
        h.manager.perform(.focusLast)
        XCTAssertEqual(h.applier.expected[4]?.minX, 505)
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.strip.focusedWindow, 1)
        XCTAssertEqual(h.applier.lastTransitions[1]?.start?.minX, 999, "first window comes in from the right")
        XCTAssertEqual(h.applier.lastTransitions[4]?.target.minX, -494, "last window leaves to the left")
        XCTAssertNil(WindowManager.loopAround(.focus(.left), from: h.strip, to: h.strip))
    }

    func testFirstFocusCommandReturnsFocusToStrip() {
        let h = Harness().start([1, 2], focused: nil)
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.windows.focusCalls, [1], "focus was elsewhere → focus the strip's window first")
    }

    func testMoveAndWidthCommands() {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.manager.perform(.move(.right))
        XCTAssertEqual(h.order, [[2], [1], [3]])
        XCTAssertTrue(h.windows.focusCalls.isEmpty, "focus didn't change")
        h.manager.perform(.toggleFullWidth)
        XCTAssertEqual(h.applier.expected[1]?.width, 1000)
        h.manager.perform(.cycleWidth)
        XCTAssertEqual(h.strip.columns[1].widthFraction, 1.0 / 3.0, accuracy: 1e-9)
        h.manager.perform(.centreColumn)
        XCTAssertNotEqual(h.strip.viewportOffset, 0)
    }

    func testStackCommandsAndTabBars() {
        let h = Harness().start([1, 2, 3], focused: 2)
        h.windows.emit(.windowFocused(2))
        h.manager.perform(.stackIntoLeft)
        XCTAssertEqual(h.order, [[1, 2], [3]])
        let frames = (h.applier.expected[1]!, h.applier.expected[2]!)
        XCTAssertEqual(frames.0.minY, 25)
        XCTAssertGreaterThan(frames.1.minY, frames.0.maxY)
        h.manager.perform(.toggleTabbed)
        XCTAssertEqual(h.overlays.tabBars.first?.tabs.map(\.window), [1, 2])
        XCTAssertEqual(h.overlays.tabBars.first?.activeIndex, 1)
        h.overlays.tabClickHandler?(1)
        XCTAssertEqual(h.windows.focusCalls.last, 1)
        XCTAssertEqual(h.strip.focusedWindow, 1)
        h.manager.perform(.popOutRight)
        XCTAssertEqual(h.order, [[2], [1], [3]])
    }

    func testTabBarsCanBeTurnedOff() {
        var settings = Harness.testSettings
        settings.appearance.tabBarsEnabled = false
        let h = Harness(settings: settings).start([1, 2], focused: 1)
        h.manager.perform(.stackIntoRight)
        h.manager.perform(.toggleTabbed)
        XCTAssertTrue(h.overlays.tabBars.isEmpty)
        XCTAssertEqual(h.applier.expected[1]?.minY, 25, "no space reserved for a bar")
    }

    func testToggleFloatBothWays() {
        let h = Harness().start([1, 2], focused: 2)
        h.windows.emit(.windowFocused(2))
        h.manager.perform(.toggleFloat)
        XCTAssertEqual(h.manager.world.floating, [2])
        XCTAssertEqual(h.order, [[1]])
        let centred = h.applier.lastTransitions[2]?.target
        XCTAssertEqual(centred?.midX ?? 0, 500, accuracy: 1)
        h.manager.perform(.toggleFloat)
        XCTAssertTrue(h.manager.world.floating.isEmpty)
        XCTAssertEqual(h.order, [[1], [2]])
    }

    func testSendToNextDisplay() {
        let h = Harness(displays: [Harness.mainDisplay, Harness.rightDisplay])
        h.windows.add(h.win(1, x: 0))
        h.windows.add(h.win(2, x: 1200))
        h.windows.focused = 1
        h.manager.start()
        XCTAssertEqual(h.manager.world.strip(StripKey(displayUUID: "RIGHT", spaceID: 0)).allWindows, [2])
        h.manager.perform(.sendToNextDisplay)
        XCTAssertEqual(h.manager.world.strip(StripKey(displayUUID: "RIGHT", spaceID: 0)).allWindows, [2, 1])
        XCTAssertTrue(h.strip.isEmpty)
        XCTAssertGreaterThanOrEqual(h.applier.expected[1]!.minX, 1000)
        XCTAssertEqual(h.windows.focusCalls.last, 1)
    }

    func testIndicatorFollowsNavigationAndModifierHold() {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.overlays.indicatorShows.last?.persistent, false)
        XCTAssertEqual(h.overlays.indicatorShows.last?.model.tiles.count, 3)
        XCTAssertEqual(h.overlays.indicatorShows.last?.model.focusedIndex, 1)
        h.hotkeys.modifierHoldHandler?(true)
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.overlays.indicatorShows.last?.persistent, true)
        let range = h.overlays.indicatorShows.last!.model.visibleRange
        XCTAssertGreaterThan(range.lowerBound, 0)
        h.hotkeys.modifierHoldHandler?(false)
        XCTAssertEqual(h.overlays.indicatorShows.last?.persistent, false)
        h.overlays.tileClickHandler?(0)
        XCTAssertEqual(h.strip.focusedWindow, 1)
        h.overlays.tileReorderHandler?(0, 2)
        XCTAssertEqual(h.order, [[2], [3], [1]])
    }

    func testIndicatorDisabled() {
        var settings = Harness.testSettings
        settings.appearance.indicatorEnabled = false
        let h = Harness(settings: settings).start([1, 2], focused: 1)
        h.manager.perform(.focus(.right))
        h.manager.perform(.showIndicator)
        XCTAssertTrue(h.overlays.indicatorShows.isEmpty)
    }

    func testMouseFollowsFocus() {
        var settings = Harness.testSettings
        settings.behavior.mouseFollowsFocus = true
        let h = Harness(settings: settings).start([1, 2], focused: 1)
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.input.warps.last?.x ?? 0, 752, accuracy: 2)
    }

    func testGeneralCommands() {
        let h = Harness().start([1])
        var opened = 0
        h.manager.openSettingsHandler = { opened += 1 }
        h.manager.perform(.openSettings)
        XCTAssertEqual(opened, 1)
        let before = h.applier.applied.count
        h.manager.perform(.gatherWindows)
        XCTAssertGreaterThan(h.applier.applied.count, before)
        h.manager.relayout()
        h.manager.perform(.toggleEnabled)
        XCTAssertFalse(h.manager.isEnabled)
        h.manager.perform(.openSettings)
        XCTAssertEqual(opened, 2, "settings open even while paused")
        h.manager.perform(.gatherWindows)
    }
}
