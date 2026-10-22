import CoreGraphics
import XCTest
import RibbonCore
@testable import RibbonEngine

final class LifecycleTests: XCTestCase {
    func testInitialScanTilesWindowsInOnScreenOrder() {
        let h = Harness()
        h.windows.add(h.win(1, x: 600))
        h.windows.add(h.win(2, x: 0))
        h.windows.add(h.win(3, x: 300))
        h.windows.focused = 3
        h.manager.start()
        XCTAssertEqual(h.order, [[2], [3], [1]])
        XCTAssertEqual(h.strip.focusedWindow, 3)
        XCTAssertTrue(h.manager.isEnabled)
        XCTAssertTrue(h.windows.started)
        XCTAssertEqual(h.hotkeys.registered, Harness.testSettings.bindings)
        XCTAssertTrue(h.gestures.running)
        XCTAssertTrue(h.input.tracking)
        XCTAssertEqual(h.applier.applied.first?.count, 3, "initial layout places every window")
        XCTAssertEqual(h.applier.animatedFlags.first, false)
    }

    func testDialogsFloatAndOddWindowsAreIgnored() {
        let h = Harness()
        var dialog = h.win(1)
        dialog.subrole = "AXDialog"
        var tiny = h.win(2, width: 20, height: 20)
        tiny.subrole = "AXStandardWindow"
        h.windows.add(dialog)
        h.windows.add(tiny)
        h.windows.add(h.win(3))
        h.manager.start()
        XCTAssertEqual(h.manager.world.floating, [1])
        XCTAssertEqual(h.order, [[3]])
        XCTAssertEqual(h.manager.managedWindowCount, 2)
    }

    func testRestoresSavedSessionThenAppendsNewWindows() {
        let h = Harness()
        var settings = Harness.testSettings
        settings.behavior.restoreSession = true
        h.manager.updateSettings(settings)
        let saved = Strip(columns: [Column(windows: [3], widthFraction: 0.3), Column(windows: [1, 2], widthFraction: 0.6)], focusedColumnIndex: 1)
        h.store.snapshot = SessionSnapshot(world: World(strips: [StripKey(displayUUID: "MAIN", spaceID: 0): saved]),
                                           signatures: [1: WindowSignature(bundleID: "com.test.app", title: "W1"),
                                                        2: WindowSignature(bundleID: "com.test.app", title: "W2"),
                                                        3: WindowSignature(bundleID: "com.test.app", title: "W3")])
        h.start([1, 2, 3, 4])
        XCTAssertEqual(h.order, [[3], [1, 2], [4]])
        XCTAssertEqual(h.strip.columns[0].widthFraction, 0.3)
    }

    func testRestoredStripWithStaleSpaceIsRekeyed() {
        let h = Harness()
        var settings = Harness.testSettings
        settings.behavior.restoreSession = true
        h.manager.updateSettings(settings)
        h.spaces.current["MAIN"] = 7
        h.store.snapshot = SessionSnapshot(world: World(strips: [StripKey(displayUUID: "MAIN", spaceID: 3): makeStrip([2, 1])]),
                                           signatures: [:])
        h.start([1, 2])
        XCTAssertEqual(h.order, [[2], [1]], "saved Space 3 no longer exists → merged into the current one")
    }

    func testStopUnparksAndSaves() {
        let h = Harness().start([1, 2, 3])
        XCTAssertEqual(h.applier.expected[3]?.minX, 999, "third column is parked")
        h.manager.stop()
        let restored = h.applier.lastTransitions[3]?.target
        XCTAssertNotNil(restored)
        XCTAssertTrue(Harness.mainDisplay.visibleFrame.contains(restored!.center))
        XCTAssertNil(h.applier.lastTransitions[1], "visible windows stay")
        XCTAssertNotNil(h.store.snapshot)
        XCTAssertFalse(h.manager.isEnabled)
        XCTAssertEqual(h.overlays.hideAllCount, 1)
        XCTAssertTrue(h.hotkeys.registered.isEmpty)
        h.manager.stop()
        XCTAssertEqual(h.overlays.hideAllCount, 1, "second stop is a no-op")
    }

    func testDisableUnparksAndKeepsOnlyToggleHotkey() {
        let h = Harness().start([1, 2, 3])
        h.manager.setEnabled(false)
        XCTAssertFalse(h.manager.isEnabled)
        XCTAssertTrue(h.hotkeys.registered.allSatisfy { $0.command == .toggleEnabled })
        XCTAssertFalse(h.hotkeys.registered.isEmpty)
        XCTAssertNotNil(h.applier.lastTransitions[3])
        XCTAssertFalse(h.gestures.running)
        h.manager.perform(.focus(.right))
        XCTAssertTrue(h.windows.focusCalls.isEmpty, "commands are ignored while paused")
        h.windows.add(h.win(9))
        h.windows.emit(.windowCreated(h.win(9)))
        XCTAssertFalse(h.manager.world.isManaged(9))
        h.manager.perform(.toggleEnabled)
        XCTAssertTrue(h.manager.isEnabled)
        XCTAssertEqual(h.hotkeys.registered, Harness.testSettings.bindings)
        XCTAssertTrue(h.manager.world.isManaged(9), "reconcile on resume picks up new windows")
    }

    func testUpdateSettingsRebindsAndReportsFailures() {
        let h = Harness().start([1])
        var settings = Harness.testSettings
        let combo = KeyCombo(keyCode: KeyCode.a, modifiers: .hyperLite)
        settings.bindings = [KeyBinding(command: .wider, combo: combo)]
        h.hotkeys.failing = [combo]
        h.manager.updateSettings(settings)
        XCTAssertEqual(h.hotkeys.registered, settings.bindings)
        XCTAssertEqual(h.manager.failedBindings, settings.bindings)
        XCTAssertEqual(h.gestures.configured, settings.trackpad)
        XCTAssertEqual(h.overlays.appearance, settings.appearance)
    }

    func testRuleChangeReclassifies() {
        let h = Harness()
        h.windows.add(h.win(1, x: 0))
        h.windows.add(h.win(2, x: 100, pid: 20, bundle: "com.other"))
        h.manager.start()
        var settings = Harness.testSettings
        settings.rules = [AppRule(bundleID: "com.other", appName: "Other", action: .float)]
        h.manager.updateSettings(settings)
        XCTAssertEqual(h.manager.world.floating, [2])
        XCTAssertEqual(h.order, [[1]])
        settings.rules = [AppRule(bundleID: "com.other", appName: "Other", action: .ignore)]
        h.manager.updateSettings(settings)
        XCTAssertFalse(h.manager.world.isManaged(2))
        settings.rules = []
        h.manager.updateSettings(settings)
        XCTAssertEqual(h.order, [[1], [2]], "ignored windows come back on the next reconcile")
    }

    func testSessionSaveIsDebounced() {
        let h = Harness().start([1])
        let saves = h.store.saveCount
        h.manager.perform(.wider)
        h.manager.perform(.wider)
        XCTAssertEqual(h.store.saveCount, saves)
        h.scheduler.advance(by: 1.1)
        XCTAssertEqual(h.store.saveCount, saves + 1)
    }

    func testDebugDescriptionListsStrips() {
        let h = Harness().start([1, 2])
        let dump = h.manager.debugDescription()
        XCTAssertTrue(dump.contains("Strip MAIN#0"))
        XCTAssertTrue(dump.contains("W1"))
    }

    func testReconcileTimerRunsPeriodically() {
        var settings = Harness.testSettings
        settings.behavior.reconcileInterval = 2
        let h = Harness(settings: settings).start([1])
        h.windows.add(h.win(5, x: 500))
        h.scheduler.advance(by: 2.5)
        XCTAssertTrue(h.manager.world.isManaged(5))
        h.windows.windows[5] = nil
        h.scheduler.advance(by: 2.5)
        XCTAssertFalse(h.manager.world.isManaged(5))
    }
}

func makeStrip(_ ids: [WindowID]) -> Strip {
    Strip(columns: ids.map { Column(windows: [$0], widthFraction: 0.5) })
}

final class PerformanceBehaviourTests: XCTestCase {
    func testPeriodicSweepSkipsScanWhileWindowSetIsUnchanged() {
        var settings = Harness.testSettings
        settings.behavior.reconcileInterval = 2
        let h = Harness(settings: settings).start([1, 2])
        let scans = h.windows.scanCount
        h.scheduler.advance(by: 6.5)
        XCTAssertEqual(h.windows.scanCount, scans, "nothing changed → no Accessibility scan")
        h.windows.emit(.appActivated(10))
        h.scheduler.advance(by: 0.4)
        XCTAssertEqual(h.windows.scanCount, scans, "app switches are gated too")
        h.windows.add(h.win(3, x: 900))
        h.scheduler.advance(by: 2.1)
        XCTAssertEqual(h.windows.scanCount, scans + 1)
        XCTAssertTrue(h.manager.world.isManaged(3))
    }

    func testOverlaysOnlyUpdateWhenSomethingChanged() {
        let h = Harness().start([1, 2], focused: 1)
        let updates = h.overlays.focusFrames.count
        h.manager.relayout()
        h.manager.relayout()
        XCTAssertEqual(h.overlays.focusFrames.count, updates)
        h.manager.perform(.focus(.right))
        XCTAssertEqual(h.overlays.focusFrames.count, updates + 1)
    }

    func testStopDrainsPendingWrites() {
        let h = Harness().start([1])
        h.manager.stop()
        XCTAssertEqual(h.applier.drainCount, 1)
    }

    func testIndicatorRedrawsAreThrottledDuringGestures() {
        let h = Harness().start([1, 2, 3], focused: 1)
        h.gestures.handler?(.began)
        for _ in 0..<10 { h.gestures.handler?(.changed(dx: 5)) }
        XCTAssertLessThanOrEqual(h.overlays.indicatorShows.count, 1, "same tiles within 50 ms → one redraw")
        h.scheduler.advance(by: 0.06)
        h.gestures.handler?(.changed(dx: 5))
        XCTAssertEqual(h.overlays.indicatorShows.count, 2)
    }
}
