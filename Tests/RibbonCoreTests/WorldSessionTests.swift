import CoreGraphics
import XCTest
@testable import RibbonCore

final class WorldTests: XCTestCase {
    let a = StripKey(displayUUID: "A", spaceID: 1)
    let b = StripKey(displayUUID: "B", spaceID: 1)

    func testTilingFloatingRemoving() {
        let w = World()
            .tiling(1, into: a, position: .end, widthFraction: 0.5, focus: true)
            .tiling(2, into: a, position: .end, widthFraction: 0.5, focus: false)
            .tiling(3, into: b, position: .end, widthFraction: 0.5, focus: true)
        XCTAssertEqual(w.key(containing: 2), a)
        XCTAssertEqual(w.allTiledWindows, [1, 2, 3])
        let moved = w.tiling(2, into: b, position: .afterFocused, widthFraction: 0.5, focus: true)
        XCTAssertEqual(moved.strip(a).allWindows, [1])
        XCTAssertEqual(moved.strip(b).allWindows, [3, 2])
        let floated = moved.floatingWindow(3)
        XCTAssertEqual(floated.floating, [3])
        XCTAssertFalse(floated.strip(b).contains(3))
        XCTAssertTrue(floated.isManaged(3))
        let gone = floated.removing(3).removing(1)
        XCTAssertFalse(gone.isManaged(3))
        XCTAssertNil(gone.strips[a], "empty strips are dropped")
        XCTAssertEqual(gone.strip(a), Strip())
        XCTAssertNil(World().key(containing: 1))
    }

    func testMergingStrip() {
        var target = makeStrip([10, 11], focused: 1)
        target.columns[1].pin = .right
        var source = makeStrip([1, 2])
        source.columns[0].pin = .left
        let w = World(strips: [a: source, b: target])
        let merged = w.mergingStrip(a, into: b)
        XCTAssertNil(merged.strips[a])
        XCTAssertEqual(merged.strip(b).windowsByColumn, [[10], [1], [2], [11]])
        XCTAssertEqual(merged.strip(b).focusedWindow, 11)
        XCTAssertNil(merged.strip(b).columns[1].pin)
        assertInvariants(merged.strip(b))
        let intoEmpty = World(strips: [a: source]).mergingStrip(a, into: b)
        XCTAssertEqual(intoEmpty.strip(b).focusedWindow, 1)
        XCTAssertEqual(w.mergingStrip(a, into: a), w)
    }

    func testPruning() {
        let w = World(strips: [a: makeStrip([1, 2, 3], focused: 2), b: makeStrip([4])], floating: [5, 6])
        let p = w.pruning { $0 != 3 && $0 != 4 && $0 != 6 }
        XCTAssertEqual(p.strip(a).allWindows, [1, 2])
        XCTAssertEqual(p.strip(a).focusedWindow, 2)
        XCTAssertNil(p.strips[b])
        XCTAssertEqual(p.floating, [5])
    }

    func testCodableRoundTrip() throws {
        let w = World(strips: [a: makeStrip([1, 2]), b: makeStrip([3])], floating: [9])
        let data = try JSONEncoder().encode(w)
        XCTAssertEqual(try JSONDecoder().decode(World.self, from: data), w)
        XCTAssertEqual(a.description, "A#1")
        XCTAssertLessThan(a, b)
    }
}

final class SessionTests: XCTestCase {
    let key = StripKey(displayUUID: "A", spaceID: 0)

    func snapshot(_ strip: Strip, floating: Set<WindowID> = [], signatures: [WindowID: WindowSignature]) -> SessionSnapshot {
        SessionSnapshot(world: World(strips: [key: strip], floating: floating), signatures: signatures)
    }

    func testExactIDMatchWinsOverFuzzyClaims() {
        let saved = snapshot(makeStrip([1, 2]), signatures: [
            1: WindowSignature(bundleID: "x", title: "One"),
            2: WindowSignature(bundleID: "x", title: "Two"),
        ])
        // live: id 2 still exists (same app); id 1 is gone but a new "x" window 7 exists
        let world = SessionRestorer.restore(saved, liveWindows: [info(2, bundle: "x", title: "Two"), info(7, bundle: "x", title: "Other")])
        XCTAssertEqual(world.strip(key).windowsByColumn, [[7], [2]])
    }

    func testTitleMatchBeforeBundleOnly() {
        let saved = snapshot(makeStrip([1, 2]), signatures: [
            1: WindowSignature(bundleID: "x", title: "Docs"),
            2: WindowSignature(bundleID: "x", title: "Mail"),
        ])
        let live = [info(20, bundle: "x", title: "Mail"), info(30, bundle: "x", title: "Docs")]
        XCTAssertEqual(SessionRestorer.restore(saved, liveWindows: live).strip(key).windowsByColumn, [[30], [20]])
    }

    func testIDReusedByDifferentAppIsNotMatched() {
        let saved = snapshot(makeStrip([1]), signatures: [1: WindowSignature(bundleID: "x", title: "A")])
        XCTAssertTrue(SessionRestorer.restore(saved, liveWindows: [info(1, bundle: "y")]).strips.isEmpty)
    }

    func testUnmatchedDroppedAndFloatingMapped() {
        let saved = snapshot(makeStrip([1, 2, 3], focused: 2), floating: [4], signatures: [
            1: WindowSignature(bundleID: "x", title: "1"), 3: WindowSignature(bundleID: nil, title: "3"),
            4: WindowSignature(bundleID: "f", title: "Float"),
        ])
        let world = SessionRestorer.restore(saved, liveWindows: [info(1, bundle: "x"), info(2, bundle: "z"), info(44, bundle: "f", title: "Float")])
        XCTAssertEqual(world.strip(key).windowsByColumn, [[1], [2]], "2 has no signature → id alone matches; 3 unmatched")
        XCTAssertEqual(world.strip(key).focusedWindow, 2)
        XCTAssertEqual(world.floating, [44])
        assertInvariants(world.strip(key))
    }

    func testUnknownVersionGivesEmptyWorld() {
        var saved = snapshot(makeStrip([1]), signatures: [:])
        saved.version = 99
        XCTAssertEqual(SessionRestorer.restore(saved, liveWindows: [info(1)]), World())
    }

    func testSnapshotRecordsSignatures() throws {
        let world = World(strips: [key: makeStrip([1, 2])], floating: [3])
        let snap = SessionRestorer.snapshot(of: world, windows: [1: info(1, bundle: "a", title: "T1"), 3: info(3, bundle: "c", title: "T3")])
        XCTAssertEqual(snap.signatures, [1: WindowSignature(bundleID: "a", title: "T1"), 3: WindowSignature(bundleID: "c", title: "T3")])
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded, snap)
    }
}

final class ClassifierTests: XCTestCase {
    let settings = RibbonSettings.defaults

    func testStandardWindowsTile() {
        XCTAssertEqual(WindowClassifier.classify(info(1), settings: settings, ownBundleID: "own"), .tile)
    }

    func testIgnoredWindows() {
        var w = info(1)
        w.isMinimized = true
        XCTAssertEqual(WindowClassifier.classify(w, settings: settings, ownBundleID: nil), .ignore)
        for mutate in [{ (w: inout WindowInfo) in w.isFullscreen = true }, { $0.isAppHidden = true }, { $0.isRegularApp = false },
                       { $0.subrole = "AXUnknown" }, { $0.subrole = nil }, { $0.role = "AXSheet" },
                       { $0.frame = CGRect(x: 0, y: 0, width: 30, height: 300) }] {
            var x = info(1)
            mutate(&x)
            XCTAssertEqual(WindowClassifier.classify(x, settings: settings, ownBundleID: nil), .ignore)
        }
        var nilRole = info(1)
        nilRole.role = nil
        XCTAssertEqual(WindowClassifier.classify(nilRole, settings: settings, ownBundleID: nil), .tile)
    }

    func testFloatingHeuristicsAndRules() {
        XCTAssertEqual(WindowClassifier.classify(info(1, bundle: "own"), settings: settings, ownBundleID: "own"), .float)
        XCTAssertEqual(WindowClassifier.classify(info(1, subrole: "AXDialog"), settings: settings, ownBundleID: nil), .float)
        XCTAssertEqual(WindowClassifier.classify(info(1, resizable: false), settings: settings, ownBundleID: nil), .float)
        XCTAssertEqual(WindowClassifier.classify(info(1, subrole: "AXCustomThing"), settings: settings, ownBundleID: nil), .float)
        var s = settings
        s.behavior.floatDialogs = false
        s.behavior.floatFixedSizeWindows = false
        XCTAssertEqual(WindowClassifier.classify(info(1, subrole: "AXDialog"), settings: s, ownBundleID: nil), .float, "non-standard subrole still floats")
        XCTAssertEqual(WindowClassifier.classify(info(1, resizable: false), settings: s, ownBundleID: nil), .tile)
        s.rules = [AppRule(bundleID: "com.test.app", appName: "App", action: .tile)]
        XCTAssertEqual(WindowClassifier.classify(info(1, subrole: "AXDialog", resizable: false), settings: s, ownBundleID: nil), .tile)
        s.rules = [AppRule(bundleID: "com.test.app", appName: "App", action: .float)]
        XCTAssertEqual(WindowClassifier.classify(info(1), settings: s, ownBundleID: nil), .float)
        s.rules = [AppRule(bundleID: "com.test.app", appName: "App", action: .ignore)]
        XCTAssertEqual(WindowClassifier.classify(info(1), settings: s, ownBundleID: nil), .ignore)
        XCTAssertNil(s.rule(for: nil))
    }
}
