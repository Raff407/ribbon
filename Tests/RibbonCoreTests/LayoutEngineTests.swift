import CoreGraphics
import XCTest
@testable import RibbonCore

final class LayoutGeometryTests: XCTestCase {
    func testWorkingAreaAndColumnWidth() {
        var config = testConfig
        config.outerGap = 8
        XCTAssertEqual(LayoutEngine.workingArea(visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 800), config: config),
                       CGRect(x: 8, y: 33, width: 984, height: 784))
        XCTAssertEqual(LayoutEngine.workingArea(visibleFrame: CGRect(x: 0, y: 0, width: 10, height: 10), config: config).width, 0)
        let half = Column(windows: [1], widthFraction: 0.5)
        XCTAssertEqual(LayoutEngine.columnWidth(half, areaWidth: 1000, config: testConfig), 495)
        var full = half
        full.isFullWidth = true
        XCTAssertEqual(LayoutEngine.columnWidth(full, areaWidth: 1000, config: testConfig), 1000)
        // two halves + one gap fill the area exactly
        XCTAssertEqual(LayoutEngine.stripWidth(makeStrip([1, 2]), area: testArea, config: testConfig), 1000)
        XCTAssertEqual(LayoutEngine.stripWidth(Strip(), area: testArea, config: testConfig), 0)
    }

    func testScrollableAreaWithPins() {
        var s = makeStrip([1, 2, 3], width: 0.25)
        s.columns[0].pin = .left
        s.columns[2].pin = .right
        let area = LayoutEngine.scrollableArea(s, area: testArea, config: testConfig)
        XCTAssertEqual(area.minX, 252.5, accuracy: 1e-9)
        XCTAssertEqual(area.maxX, 747.5, accuracy: 1e-9)
        XCTAssertNil(LayoutEngine.stripSpan(ofColumn: 0, in: s, area: testArea, config: testConfig))
        XCTAssertEqual(LayoutEngine.stripSpan(ofColumn: 1, in: s, area: testArea, config: testConfig), 0...242.5)
        XCTAssertNil(LayoutEngine.stripSpan(ofColumn: 7, in: s, area: testArea, config: testConfig))
    }

    func testPlacementsForSimpleStrip() {
        let s = makeStrip([1, 2, 3], width: 0.5, focused: 0)
        let p = LayoutEngine.placements(s, context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(p.map(\.window), [1, 2, 3])
        XCTAssertEqual(p[0].frame, CGRect(x: 0, y: 0, width: 495, height: 800))
        XCTAssertEqual(p[1].frame, CGRect(x: 505, y: 0, width: 495, height: 800))
        XCTAssertEqual(p[0].visibility, .visible)
        XCTAssertEqual(p[1].visibility, .visible)
        XCTAssertEqual(p[2].visibility, .hidden(.right))
        XCTAssertTrue(p[0].isFocused)
        XCTAssertFalse(p[1].isFocused)
    }

    func testPartialAndBlockedSides() {
        let s = makeStrip([1, 2, 3], width: 0.4, focused: 0)  // widths 394, gap 10
        let open = LayoutContext(area: testArea, screenFrame: testScreen)
        let p = LayoutEngine.placements(s, context: open, config: testConfig)
        XCTAssertEqual(p[2].visibility, .partial)
        let neighbour = LayoutContext(area: testArea, screenFrame: testScreen, otherScreens: [CGRect(x: 1000, y: 0, width: 800, height: 600)])
        XCTAssertEqual(neighbour.blockedSides, [.right])
        XCTAssertEqual(LayoutEngine.placements(s, context: neighbour, config: testConfig)[2].visibility, .hidden(.right))
        let scrolled = LayoutEngine.placements(s.withViewportOffset(300), context: open, config: testConfig)
        XCTAssertEqual(scrolled[0].visibility, .partial, "focused column is never hidden")
        let leftNeighbour = LayoutContext(area: testArea, screenFrame: testScreen, otherScreens: [CGRect(x: -500, y: 100, width: 500, height: 500)])
        XCTAssertEqual(leftNeighbour.blockedSides, [.left])
        let noOverlap = LayoutContext(area: testArea, screenFrame: testScreen, otherScreens: [CGRect(x: 0, y: 800, width: 1000, height: 500)])
        XCTAssertEqual(noOverlap.blockedSides, [])
    }

    func testPinnedPlacementsAndPartialNextToPinIsHidden() {
        var s = makeStrip([1, 2, 3, 4], width: 0.3, focused: 1)
        s.columns[0].pin = .left
        let p = LayoutEngine.placements(s.withViewportOffset(100), context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(p[0].frame.minX, 0)
        XCTAssertEqual(p[0].visibility, .visible)
        // column 2 (window 3) starts at scrollable.minX + 303 - 100 → fully visible; window 2 is focused → partial, not hidden
        XCTAssertEqual(p[1].visibility, .partial)
        let unfocused = LayoutEngine.placements(s.withViewportOffset(100).focusingColumn(2), context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(unfocused[1].visibility, .hidden(.left))
        var right = makeStrip([1, 2], width: 0.3)
        right.columns[1].pin = .right
        let rp = LayoutEngine.placements(right, context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(rp[1].frame.maxX, 1000)
    }

    func testStackedAndTabbedRows() {
        let stacked = Strip(columns: [Column(windows: [1, 2], heightWeights: [3, 1], widthFraction: 0.5)])
        let p = LayoutEngine.placements(stacked, context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(p[0].frame, CGRect(x: 0, y: 0, width: 495, height: 593))  // 790 * 0.75 = 592.5 → 593 (rounded)
        XCTAssertEqual(p[1].frame.minY, 603, accuracy: 1)
        XCTAssertEqual(p[1].frame.maxY, 800, accuracy: 1)
        let tabbed = Strip(columns: [Column(windows: [1, 2], activeIndex: 1, widthFraction: 0.5, mode: .tabbed)])
        let t = LayoutEngine.placements(tabbed, context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(t[1].frame, CGRect(x: 0, y: 20, width: 495, height: 780))
        XCTAssertEqual(t[1].visibility, .visible)
        XCTAssertTrue(t[1].isFocused)
        XCTAssertEqual(t[0].visibility, .hidden(.left))
    }

    func testPlacementsKeepPinnedColumnsOutOfScrollableOffsets() {
        let strip = Strip(columns: [
            Column(windows: [1], widthFraction: 0.2, pin: .left),
            Column(windows: [2, 3], widthFraction: 0.2),
            Column(windows: [4, 5], activeIndex: 1, widthFraction: 0.2, mode: .tabbed),
            Column(windows: [6], widthFraction: 0.2, pin: .right),
        ], focusedColumnIndex: 2, viewportOffset: 50)
        let placements = LayoutEngine.placements(strip, context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(placements.map(\.window), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(placements.map(\.frame.minX), [0, 152, 152, 354, 354, 808])
        XCTAssertEqual(placements.map(\.visibility), [.visible, .hidden(.left), .hidden(.left), .hidden(.left), .visible, .visible])
        XCTAssertEqual(LayoutEngine.stripWidth(strip, area: testArea, config: testConfig), 394)
    }

    func testColumnIndexAtPoint() {
        let p = LayoutEngine.placements(makeStrip([1, 2, 3]), context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(LayoutEngine.columnIndex(at: CGPoint(x: 100, y: 100), placements: p), 0)
        XCTAssertEqual(LayoutEngine.columnIndex(at: CGPoint(x: 700, y: 100), placements: p), 1)
        XCTAssertNil(LayoutEngine.columnIndex(at: CGPoint(x: 500, y: 100), placements: p), "in the gap")
        XCTAssertNil(LayoutEngine.columnIndex(at: CGPoint(x: 100, y: 900), placements: p))
    }
}

final class ViewportTests: XCTestCase {
    func config(_ mode: CentreMode) -> LayoutConfig {
        var c = testConfig
        c.centreMode = mode
        return c
    }

    func testNeverScrollsMinimally() {
        let s = makeStrip([1, 2, 3, 4], width: 0.5, focused: 2)  // spans: 0,505,1010,1515 width 495
        let r = LayoutEngine.revealFocused(s, area: testArea, config: config(.never))
        XCTAssertEqual(r.viewportOffset, 505)
        let back = LayoutEngine.revealFocused(r.focusingColumn(0), area: testArea, config: config(.never))
        XCTAssertEqual(back.viewportOffset, 0)
        let visible = LayoutEngine.revealFocused(r.focusingColumn(1), area: testArea, config: config(.never))
        XCTAssertEqual(visible.viewportOffset, 505, "already visible → no scroll")
    }

    func testNeverClampsAndLeftAlignsWideColumns() {
        var s = makeStrip([1, 2], width: 0.5, focused: 1, offset: -300)
        XCTAssertEqual(LayoutEngine.revealFocused(s, area: testArea, config: config(.never)).viewportOffset, 0)
        s.columns[1].widthFraction = 1
        s.columns[0].widthFraction = 1
        s.columns.append(Column(windows: [3], widthFraction: 0.3))
        let wide = LayoutEngine.revealFocused(s.focusingColumn(1), area: testArea, config: config(.never))
        XCTAssertEqual(wide.viewportOffset, 1010)
    }

    func testOnOverflow() {
        let fits = makeStrip([1, 2], width: 0.5, focused: 1, offset: 50)
        XCTAssertEqual(LayoutEngine.revealFocused(fits, area: testArea, config: config(.onOverflow)).viewportOffset, 0)
        let over = makeStrip([1, 2, 3, 4], width: 0.5, focused: 2)
        let centred = LayoutEngine.revealFocused(over, area: testArea, config: config(.onOverflow))
        XCTAssertEqual(centred.viewportOffset, 1010 + 247.5 - 500)
        let narrow = makeStrip([1, 2, 3, 4, 5, 6], width: 0.25, focused: 1)
        XCTAssertEqual(LayoutEngine.revealFocused(narrow, area: testArea, config: config(.onOverflow)).viewportOffset, 0,
                       "overflowing but the focused column is already visible → no scroll")
        let last = LayoutEngine.revealFocused(over.focusingColumn(3), area: testArea, config: config(.onOverflow))
        XCTAssertEqual(last.viewportOffset, 1010, "clamped to the strip end")
    }

    func testAlwaysCentresUnclamped() {
        let s = makeStrip([1, 2, 3], width: 0.5, focused: 0)
        XCTAssertEqual(LayoutEngine.revealFocused(s, area: testArea, config: config(.always)).viewportOffset, 247.5 - 500)
        XCTAssertEqual(LayoutEngine.clampViewport(s.withViewportOffset(-100), area: testArea, config: config(.always)).viewportOffset, -100)
        XCTAssertEqual(LayoutEngine.clampViewport(s.withViewportOffset(-100), area: testArea, config: config(.never)).viewportOffset, 0)
        XCTAssertEqual(LayoutEngine.clampViewport(s.withViewportOffset(5000), area: testArea, config: config(.never)).viewportOffset, 505)
    }

    func testPinnedFocusedColumnUnchanged() {
        var s = makeStrip([1, 2], focused: 0, offset: 33)
        s.columns[0].pin = .left
        XCTAssertEqual(LayoutEngine.revealFocused(s, area: testArea, config: config(.always)), s)
        XCTAssertEqual(LayoutEngine.revealFocused(Strip(), area: testArea, config: testConfig), Strip())
    }

    func testSnap() {
        let s = makeStrip([1, 2, 3, 4], width: 0.5, focused: 0, offset: 300)
        let snapped = LayoutEngine.snap(s, area: testArea, config: config(.never), velocity: 0)
        XCTAssertEqual(snapped.viewportOffset, 505)
        XCTAssertEqual(snapped.focusedWindow, 2, "old focus scrolled away → most visible column")
        let flung = LayoutEngine.snap(s, area: testArea, config: config(.never), velocity: 5000)
        XCTAssertEqual(flung.viewportOffset, 1010)
        let back = LayoutEngine.snap(s.withViewportOffset(100), area: testArea, config: config(.never), velocity: 0)
        XCTAssertEqual(back.viewportOffset, 0)
        XCTAssertEqual(back.focusedWindow, 1, "focused column fully visible → kept")
        let centred = LayoutEngine.snap(s.withViewportOffset(300), area: testArea, config: config(.always), velocity: 0)
        XCTAssertEqual(centred.viewportOffset, 505 + 247.5 - 500)
        XCTAssertEqual(LayoutEngine.snap(Strip(viewportOffset: 30), area: testArea, config: config(.never), velocity: 0).viewportOffset, 0)
    }
}

final class LoopAroundTransitionTests: XCTestCase {
    func testLoopAroundKeepsTravellingInOneDirection() {
        // 4 half-width columns; viewport showed columns 2 and 3, focus wraps to column 0.
        let context = LayoutContext(area: testArea, screenFrame: testScreen)
        let after = makeStrip([1, 2, 3, 4], width: 0.5, focused: 0, offset: 0)
        let p = LayoutEngine.placements(after, context: context, config: testConfig)
        let current: [WindowID: CGRect] = [
            1: CGRect(x: -494, y: 799, width: 495, height: 800),   // parked left
            2: CGRect(x: -494, y: 799, width: 495, height: 800),
            3: CGRect(x: 0, y: 0, width: 495, height: 800),        // were on screen
            4: CGRect(x: 505, y: 0, width: 495, height: 800),
        ]
        let t = LayoutEngine.transitions(p, currentFrames: current, context: context, config: testConfig, entering: .right)
        XCTAssertEqual(t[1]?.start?.minX, 999, "arrives from the right edge")
        XCTAssertEqual(t[2]?.start?.minX, 999)
        XCTAssertEqual(t[3]?.target.minX, -494, "leaves through the left edge")
        XCTAssertEqual(t[4]?.target.minX, -494)
        XCTAssertEqual(t[4]?.final?.minX, 999, "then parks on its usual side")
        let plain = LayoutEngine.transitions(p, currentFrames: current, context: context, config: testConfig)
        XCTAssertEqual(plain[3]?.target.minX, 999, "without the hint, hidden windows exit on their own side")
    }

    func testVisibleWindowThatWouldRewindStartsFromTheEnteringEdge() {
        let context = LayoutContext(area: testArea, screenFrame: testScreen)
        let p = LayoutEngine.placements(makeStrip([1, 2, 3], width: 0.5, focused: 0), context: context, config: testConfig)
        let current: [WindowID: CGRect] = [2: CGRect(x: 0, y: 0, width: 495, height: 800)]   // moving right = backwards
        let t = LayoutEngine.transitions(p, currentFrames: current, context: context, config: testConfig, entering: .right)
        XCTAssertEqual(t[2]?.start?.minX, 999)
        XCTAssertNil(LayoutEngine.transitions(p, currentFrames: current, context: context, config: testConfig)[2]?.start)
    }
}

final class ParkingAndTransitionTests: XCTestCase {
    let size = CGSize(width: 400, height: 300)

    func testParkedFrameCorners() {
        XCTAssertEqual(LayoutEngine.parkedFrame(size: size, side: .right, screen: testScreen, otherScreens: [], sliver: 1),
                       CGRect(x: 999, y: 799, width: 400, height: 300))
        XCTAssertEqual(LayoutEngine.parkedFrame(size: size, side: .left, screen: testScreen, otherScreens: [], sliver: 1),
                       CGRect(x: -399, y: 799, width: 400, height: 300))
    }

    func testParkedFrameAvoidsNeighbours() {
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        XCTAssertEqual(LayoutEngine.parkedFrame(size: size, side: .right, screen: testScreen, otherScreens: [right], sliver: 1).minX, -399)
        let left = CGRect(x: -1000, y: 0, width: 1000, height: 2000)
        let both = LayoutEngine.parkedFrame(size: size, side: .right, screen: testScreen, otherScreens: [right, left], sliver: 1)
        XCTAssertEqual(both.minX, 999, "right overlaps less (1200 tall vs 2000)")
    }

    func testTransitions() {
        let s = makeStrip([1, 2, 3], width: 0.5, focused: 0)
        let context = LayoutContext(area: testArea, screenFrame: testScreen)
        let p = LayoutEngine.placements(s, context: context, config: testConfig)
        let parked3 = LayoutEngine.parkedFrame(size: p[2].frame.size, side: .right, screen: testScreen, otherScreens: [], sliver: 1)
        let current: [WindowID: CGRect] = [
            1: CGRect(x: 50, y: 50, width: 495, height: 800),
            2: CGRect(x: 999, y: 799, width: 495, height: 800),   // parked → slides in from the right edge
            3: CGRect(x: 505, y: 0, width: 495, height: 800),     // visible → slides out, then parks
        ]
        let t = LayoutEngine.transitions(p, currentFrames: current, context: context, config: testConfig)
        XCTAssertEqual(t[1], FrameTransition(target: p[0].frame))
        XCTAssertEqual(t[2]?.start, CGRect(x: 999, y: 0, width: 495, height: 800))
        XCTAssertEqual(t[2]?.target, p[1].frame)
        XCTAssertEqual(t[3]?.target.minX, 999, "slides just past the right edge")
        XCTAssertEqual(t[3]?.final, parked3)
        XCTAssertEqual(t[3]?.settledFrame, parked3)

        let again = LayoutEngine.transitions(p, currentFrames: [3: parked3], context: context, config: testConfig)
        XCTAssertEqual(again[3], FrameTransition(target: parked3))
        XCTAssertNotNil(again[1]?.start, "unknown current frame slides in")
        let leftHidden = LayoutEngine.placements(s.withViewportOffset(1010).focusingColumn(2), context: context, config: testConfig)
        let lt = LayoutEngine.transitions(leftHidden, currentFrames: [1: CGRect(x: 0, y: 0, width: 495, height: 800)], context: context, config: testConfig)
        XCTAssertEqual(lt[1]?.target.minX, -494)
        XCTAssertEqual(lt[1]?.final?.minX, -494)
    }
}
