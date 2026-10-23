import CoreGraphics
import XCTest
import RibbonCore
@testable import RibbonEngine

final class EngineRegressionTests: XCTestCase {
    func testDisableCancelsDelayedCloseFocusEvenAfterImmediateResume() {
        let h = Harness().start([1, 2], focused: 2)
        h.windows.windows[2] = nil
        h.windows.emit(.windowDestroyed(2))
        h.manager.setEnabled(false)
        h.manager.setEnabled(true)
        h.scheduler.advance(by: 0.1)
        XCTAssertTrue(h.windows.focusCalls.isEmpty)
    }

    func testStopCancelsDelayedFullscreenRestore() {
        let h = Harness().start([1, 2], focused: 1)
        h.windows.emit(.windowFullscreenChanged(1, true))
        h.windows.emit(.windowFullscreenChanged(1, false))
        h.manager.stop()
        let stopped = h.manager.world
        h.scheduler.advance(by: 0.6)
        XCTAssertEqual(h.manager.world, stopped)
    }

    func testReenteringFullscreenCancelsPendingRestore() {
        let h = Harness().start([1, 2], focused: 1)
        h.windows.emit(.windowFullscreenChanged(1, true))
        h.windows.emit(.windowFullscreenChanged(1, false))
        h.windows.windows[1]?.isFullscreen = true
        h.windows.emit(.windowFullscreenChanged(1, true))
        h.scheduler.advance(by: 0.6)
        XCTAssertFalse(h.manager.world.isManaged(1))
        XCTAssertNotNil(h.manager.restoreHints[1])
    }

    func testPauseClearsGestureDragAndPendingFocusState() {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.gestures.handler?(.began)
        h.manager.draggedWindow = 1
        h.manager.perform(.focus(.right))
        h.manager.setEnabled(false)
        XCTAssertNil(h.manager.gestureKey)
        XCTAssertNil(h.manager.draggedWindow)
        XCTAssertNil(h.manager.pendingFocus)
        h.manager.setEnabled(true)
        h.windows.emit(.windowFocused(1))
        XCTAssertEqual(h.manager.focusedWindowID, 1)
    }

    func testPauseAndStopCancelAnimationsBeforeUnparking() {
        let paused = Harness().start([1, 2, 3])
        paused.manager.setEnabled(false)
        XCTAssertEqual(paused.applier.cancelCount, 1)
        XCTAssertNotNil(paused.applier.lastTransitions[3])
        let stopped = Harness().start([1, 2, 3])
        stopped.manager.stop()
        XCTAssertEqual(stopped.applier.cancelCount, 1)
        XCTAssertNotNil(stopped.applier.lastTransitions[3])
    }

    func testPauseAndStopRecoverRevealingWindowsStillParkedWhenCancelled() {
        for stop in [false, true] {
            let h = Harness().start([1, 2], focused: 1)
            let target = h.applier.expected[1]!
            // As in AXFrameApplier, the expected target is on screen until cancellation
            // changes it to the animation's latest position near the screen edge.
            h.applier.animating = true
            h.applier.framesAfterCancelling[1] = CGRect(x: 999, y: 799, width: target.width, height: target.height)
            if stop { h.manager.stop() } else { h.manager.setEnabled(false) }
            XCTAssertNotNil(h.applier.lastTransitions[1])
            XCTAssertTrue(Harness.mainDisplay.visibleFrame.contains(h.applier.expected[1]!.center))
            XCTAssertNil(h.applier.lastTransitions[2], "an already visible window remains where it was")
        }
    }

    func testShowingAppDoesNotRestoreItsMinimizedWindows() {
        let h = Harness().start([1, 2], focused: 1)
        h.windows.windows[2]?.isMinimized = true
        h.windows.emit(.windowMinimized(2))
        h.windows.emit(.appHidden(10))
        h.windows.emit(.appShown(10))
        XCTAssertEqual(h.order, [[1]])
        XCTAssertNotNil(h.manager.restoreHints[2])
        h.windows.windows[2]?.isMinimized = false
        h.windows.emit(.windowDeminimized(2))
        XCTAssertEqual(h.order, [[1], [2]])
    }

    func testRepeatedRestoreDoesNotBreakStackOrResetWidth() {
        let h = Harness().start([1, 2], focused: 1)
        h.manager.perform(.stackIntoRight)
        h.manager.perform(.wider)
        let before = h.manager.world
        h.windows.emit(.windowDeminimized(1))
        XCTAssertEqual(h.manager.world, before)
    }

    func testDeminimizingWhileAppIsHiddenWaitsUntilAppIsShown() {
        let h = Harness().start([1, 2], focused: 1)
        h.windows.windows[2]?.isMinimized = true
        h.windows.emit(.windowMinimized(2))
        for id in [WindowID(1), 2] { h.windows.windows[id]?.isAppHidden = true }
        h.windows.emit(.appHidden(10))
        h.windows.windows[2]?.isMinimized = false
        h.windows.emit(.windowDeminimized(2))
        XCTAssertFalse(h.manager.world.isManaged(2))
        XCTAssertNotNil(h.manager.restoreHints[2])
        for id in [WindowID(1), 2] { h.windows.windows[id]?.isAppHidden = false }
        h.windows.emit(.appShown(10))
        XCTAssertEqual(h.order, [[1], [2]])
        XCTAssertTrue(h.manager.restoreHints.isEmpty)
    }

    func testHiddenAppStateSurvivesFailedAXReadDuringDeminimize() {
        let h = Harness().start([1, 2], focused: 1)
        h.windows.emit(.windowMinimized(2))
        h.windows.unavailableInfo = [2]
        h.windows.emit(.appHidden(10))
        h.windows.emit(.windowDeminimized(2))
        XCTAssertTrue(h.order.isEmpty)
        XCTAssertEqual(h.manager.infos[2]?.isAppHidden, true)
        XCTAssertNotNil(h.manager.restoreHints[2])
        h.windows.emit(.appShown(10))
        XCTAssertEqual(h.order, [[1], [2]])
        XCTAssertEqual(h.manager.infos[2]?.isAppHidden, false)
    }

    func testHiddenAppStateSurvivesFailedAXReadDuringFullscreenExit() {
        let h = Harness().start([1, 2], focused: 1)
        h.windows.emit(.windowFullscreenChanged(2, true))
        h.windows.unavailableInfo = [2]
        h.windows.emit(.appHidden(10))
        h.windows.emit(.windowFullscreenChanged(2, false))
        h.scheduler.advance(by: 0.6)
        XCTAssertTrue(h.order.isEmpty)
        XCTAssertEqual(h.manager.infos[2]?.isAppHidden, true)
        XCTAssertNotNil(h.manager.restoreHints[2])
        h.windows.emit(.appShown(10))
        XCTAssertEqual(h.order, [[1], [2]])
    }

    func testClosingActiveNativeTabRepairsFocusedWindow() {
        let h = Harness()
        h.windows.add(h.win(1, x: 0))
        h.windows.add(h.win(2, x: 0))
        h.windows.focused = 1
        h.windows.onScreenOverride = [1]
        h.manager.start()
        h.windows.windows[1] = nil
        h.windows.onScreenOverride = [2]
        h.windows.emit(.windowDestroyed(1))
        XCTAssertEqual(h.order, [[2]])
        XCTAssertEqual(h.manager.focusedWindowID, 2)
        XCTAssertNotNil(h.overlays.focusFrames.last!)
    }

    func testTerminatedAppClearsPendingChecksAndPerWindowCaches() {
        let h = Harness().start([1], focused: 1)
        var pending = h.win(2)
        pending.frame = h.applier.expected[1]!
        h.windows.add(pending)
        h.windows.emit(.windowCreated(pending))
        h.manager.widthAdoptions[1] = h.scheduler.now()
        h.windows.emit(.appTerminated(10))
        XCTAssertTrue(h.manager.pendingTabChecks.isEmpty)
        XCTAssertTrue(h.manager.lastLayoutTime.isEmpty)
        XCTAssertTrue(h.manager.widthAdoptions.isEmpty)
    }

    func testTabBarsFollowActiveRowsAcrossMixedColumns() {
        // The last column only partly fits; peek mode keeps it (and its tab bar) on screen.
        var settings = Harness.testSettings
        settings.layout.showsPartialColumns = true
        let h = Harness(settings: settings).start(Array(1...8).map(WindowID.init), focused: 1)
        h.manager.world = World(strips: [h.key: Strip(columns: [
            Column(windows: [1, 2], activeIndex: 1, widthFraction: 0.2, mode: .tabbed),
            Column(windows: [3, 4], widthFraction: 0.2),
            Column(windows: [5, 6], widthFraction: 0.2, mode: .tabbed),
            Column(windows: [7, 8], activeIndex: 1, widthFraction: 1, mode: .tabbed),
        ])])
        h.manager.relayout()
        XCTAssertEqual(h.overlays.tabBars.map { $0.tabs.map(\.window) }, [[1, 2], [5, 6], [7, 8]])
        XCTAssertEqual(h.overlays.tabBars.map(\.activeIndex), [1, 0, 1])
        XCTAssertEqual(h.overlays.tabBars.map(\.frame.minX), [0, 404, 606])

        var strip = h.strip
        strip.viewportOffset = 1010
        strip.focusedColumnIndex = 3
        h.manager.world = h.manager.world.setting(strip, for: h.key)
        h.manager.relayout()
        XCTAssertEqual(h.overlays.tabBars.map { $0.tabs.map(\.window) }, [[7, 8]])
    }
}
