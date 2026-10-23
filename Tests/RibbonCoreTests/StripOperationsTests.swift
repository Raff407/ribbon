import XCTest
@testable import RibbonCore

final class StripInsertRemoveTests: XCTestCase {
    func testInsertIntoEmptyStripFocusesIt() {
        let s = Strip().inserting(1, position: .afterFocused, widthFraction: 0.5, focus: false)
        XCTAssertEqual(s.windowsByColumn, [[1]])
        XCTAssertEqual(s.focusedColumnIndex, 0)
        assertInvariants(s)
    }

    func testInsertAfterFocusedWithFocus() {
        let s = makeStrip([1, 2, 3], focused: 1).inserting(9, position: .afterFocused, widthFraction: 0.3, focus: true)
        XCTAssertEqual(s.windowsByColumn, [[1], [2], [9], [3]])
        XCTAssertEqual(s.focusedColumnIndex, 2)
        XCTAssertEqual(s.columns[2].widthFraction, 0.3)
        assertInvariants(s)
    }

    func testInsertWithoutFocusKeepsFocusedColumn() {
        let s = makeStrip([1, 2], focused: 1).inserting(9, position: .at(0), widthFraction: 0.5, focus: false)
        XCTAssertEqual(s.windowsByColumn, [[9], [1], [2]])
        XCTAssertEqual(s.focusedWindow, 2)
        assertInvariants(s)
    }

    func testInsertEndAndClampedAt() {
        let s = makeStrip([1, 2]).inserting(9, position: .end, widthFraction: 0.5, focus: false)
        XCTAssertEqual(s.windowsByColumn, [[1], [2], [9]])
        let t = s.inserting(10, position: .at(99), widthFraction: 0.5, focus: false)
        XCTAssertEqual(t.windowsByColumn.last, [10])
        let u = s.inserting(11, position: .at(-5), widthFraction: 0.5, focus: false)
        XCTAssertEqual(u.windowsByColumn.first, [11])
    }

    func testInsertDuplicateIsNoOp() {
        let s = makeStrip([1, 2])
        XCTAssertEqual(s.inserting(2, position: .end, widthFraction: 0.5, focus: true), s)
    }

    func testInsertRespectsPins() {
        var s = makeStrip([1, 2, 3], focused: 2)
        s.columns[0].pin = .left
        s.columns[2].pin = .right
        let after = s.inserting(9, position: .afterFocused, widthFraction: 0.5, focus: true)
        XCTAssertEqual(after.windowsByColumn, [[1], [2], [9], [3]])
        let start = s.inserting(10, position: .at(0), widthFraction: 0.5, focus: false)
        XCTAssertEqual(start.windowsByColumn, [[1], [10], [2], [3]])
        let end = s.inserting(11, position: .end, widthFraction: 0.5, focus: false)
        XCTAssertEqual(end.windowsByColumn, [[1], [2], [11], [3]])
        [after, start, end].forEach { assertInvariants($0) }
    }

    func testRemoveFocusedColumnMovesFocusLeft() {
        let s = makeStrip([1, 2, 3], focused: 2).removing(3)
        XCTAssertEqual(s.windowsByColumn, [[1], [2]])
        XCTAssertEqual(s.focusedColumnIndex, 1)
        let first = makeStrip([1, 2, 3], focused: 0).removing(1)
        XCTAssertEqual(first.focusedWindow, 2)
        assertInvariants(s)
    }

    func testRemoveOtherColumnKeepsFocusedWindow() {
        let s = makeStrip([1, 2, 3], focused: 2).removing(1)
        XCTAssertEqual(s.focusedWindow, 3)
        let t = makeStrip([1, 2, 3], focused: 0).removing(3)
        XCTAssertEqual(t.focusedWindow, 1)
    }

    func testRemoveLastWindowEmptiesStrip() {
        let s = makeStrip([1]).removing(1)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.focusedColumnIndex)
        XCTAssertEqual(makeStrip([1]).removing(5), makeStrip([1]))
    }

    func testRemoveFromStackClampsActiveIndex() {
        let s = Strip(columns: [Column(windows: [1, 2, 3], heightWeights: [1, 2, 3], activeIndex: 2, widthFraction: 0.5)])
        let a = s.removing(3)
        XCTAssertEqual(a.columns[0].windows, [1, 2])
        XCTAssertEqual(a.columns[0].heightWeights, [1, 2])
        XCTAssertEqual(a.columns[0].activeIndex, 1)
        let b = s.removing(1)
        XCTAssertEqual(b.columns[0].activeIndex, 1)
        XCTAssertEqual(b.columns[0].activeWindow, 3)
        let c = Strip(columns: [Column(windows: [1, 2, 3], activeIndex: 1, widthFraction: 0.5)]).removing(2)
        XCTAssertEqual(c.columns[0].activeWindow, 1)
        [a, b, c].forEach { assertInvariants($0) }
    }

    func testFocusingAndReplacing() {
        let s = Strip(columns: [Column(windows: [1], widthFraction: 0.5), Column(windows: [2, 3], widthFraction: 0.5)])
        let f = s.focusing(3)
        XCTAssertEqual(f.focusedColumnIndex, 1)
        XCTAssertEqual(f.focusedWindow, 3)
        XCTAssertEqual(s.focusing(99), s)
        let r = f.replacing(3, with: 7)
        XCTAssertEqual(r.windowsByColumn, [[1], [2, 7]])
        XCTAssertEqual(r.focusedWindow, 7)
        XCTAssertEqual(f.replacing(3, with: 1), f, "new already present")
        XCTAssertEqual(f.replacing(42, with: 8), f)
    }

    func testMovingColumn() {
        let s = makeStrip([1, 2, 3, 4], focused: 1)
        let a = s.movingColumn(from: 1, to: 3)
        XCTAssertEqual(a.windowsByColumn, [[1], [3], [4], [2]])
        XCTAssertEqual(a.focusedWindow, 2)
        let b = s.movingColumn(from: 0, to: 2)
        XCTAssertEqual(b.windowsByColumn, [[2], [3], [1], [4]])
        XCTAssertEqual(b.focusedWindow, 2)
        let c = s.movingColumn(from: 3, to: 0)
        XCTAssertEqual(c.focusedWindow, 2)
        XCTAssertEqual(s.movingColumn(from: 2, to: 2), s)
        XCTAssertEqual(s.movingColumn(from: 9, to: 0), s)
    }

    func testMovingColumnCantPassPins() {
        var s = makeStrip([1, 2, 3, 4], focused: 2)
        s.columns[0].pin = .left
        s.columns[3].pin = .right
        XCTAssertEqual(s.movingColumn(from: 2, to: 0).windowsByColumn, [[1], [3], [2], [4]])
        XCTAssertEqual(s.movingColumn(from: 1, to: 9).windowsByColumn, [[1], [3], [2], [4]])
        XCTAssertEqual(s.movingColumn(from: 0, to: 2), s, "pinned column can't move")
    }

    func testSettingWidthAndHeightShare() {
        var s = makeStrip([1, 2])
        s.columns[0].isFullWidth = true
        let w = s.settingWidthFraction(2, ofColumnContaining: 1, config: testConfig)
        XCTAssertEqual(w.columns[0].widthFraction, 1)
        XCTAssertFalse(w.columns[0].isFullWidth)
        XCTAssertEqual(s.settingWidthFraction(0.01, ofColumnContaining: 2, config: testConfig).columns[1].widthFraction, 0.1)
        XCTAssertEqual(s.settingWidthFraction(0.3, ofColumnContaining: 9, config: testConfig), s)

        let stack = Strip(columns: [Column(windows: [1, 2], widthFraction: 0.5)])
        let h = stack.settingHeightShare(0.75, of: 1)
        XCTAssertEqual(h.columns[0].heightWeights[0], 0.75, accuracy: 1e-9)
        XCTAssertEqual(h.columns[0].heightWeights[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(stack.settingHeightShare(0.99, of: 1).columns[0].heightWeights[1], 0.1, accuracy: 1e-9)
        XCTAssertEqual(makeStrip([1]).settingHeightShare(0.3, of: 1), makeStrip([1]), "single window column")
    }
}

final class StripCommandTests: XCTestCase {
    func testFocusLeftRightNoWrap() {
        var noWrap = testConfig
        noWrap.wrapsAround = false
        let s = makeStrip([1, 2, 3], focused: 0)
        XCTAssertEqual(s.run(.focus(.left), config: noWrap), s)
        XCTAssertEqual(s.run(.focus(.right)).focusedWindow, 2)
        XCTAssertEqual(s.run(.focus(.right), .focus(.right), .focus(.right), config: noWrap).focusedWindow, 3)
        XCTAssertEqual(s.run(.focusLast).focusedWindow, 3)
        XCTAssertEqual(s.run(.focusLast, .focusFirst).focusedWindow, 1)
        XCTAssertEqual(s.run(.focusColumn(2)).focusedWindow, 2)
        XCTAssertEqual(s.run(.focusColumn(9)), s)
    }

    func testFocusAndMoveWrapAround() {
        let s = makeStrip([1, 2, 3], focused: 0)
        XCTAssertEqual(s.run(.focus(.left)).focusedWindow, 3, "left from the first → last")
        XCTAssertEqual(s.run(.focusLast, .focus(.right)).focusedWindow, 1, "right from the last → first")
        XCTAssertEqual(s.run(.focus(.right), .focus(.right), .focus(.right)).focusedWindow, 1)
        let movedLeft = s.run(.move(.left))
        XCTAssertEqual(movedLeft.windowsByColumn, [[2], [3], [1]], "moving past the start lands at the end")
        XCTAssertEqual(movedLeft.focusedWindow, 1)
        let movedRight = s.run(.focusLast, .move(.right))
        XCTAssertEqual(movedRight.windowsByColumn, [[3], [1], [2]])
        XCTAssertEqual(makeStrip([1]).run(.focus(.right), .move(.left)), makeStrip([1]), "a single column stays put")
        var pinned = makeStrip([1, 2, 3, 4], focused: 1)
        pinned.columns[0].pin = .left
        let wrapped = pinned.run(.move(.left))
        XCTAssertEqual(wrapped.windowsByColumn, [[1], [3], [4], [2]], "never passes a pin; loops within the scrollable columns")
        XCTAssertEqual(wrapped.columns[0].pin, .left)
        XCTAssertEqual(pinned.run(.focusFirst, .move(.right)), pinned.run(.focusFirst), "pinned columns don't move")
        [movedLeft, movedRight, wrapped].forEach { assertInvariants($0) }
    }

    func testFocusUpDownInStack() {
        let s = Strip(columns: [Column(windows: [1, 2, 3], widthFraction: 0.5)])
        XCTAssertEqual(s.run(.focus(.up)), s)
        XCTAssertEqual(s.run(.focus(.down)).focusedWindow, 2)
        XCTAssertEqual(s.run(.focus(.down), .focus(.down), .focus(.down)).focusedWindow, 3)
        XCTAssertEqual(s.run(.focus(.down), .focus(.up)).focusedWindow, 1)
    }

    func testMoveLeftRightSwapsAndFocusFollows() {
        let s = makeStrip([1, 2, 3], focused: 1)
        let l = s.run(.move(.left))
        XCTAssertEqual(l.windowsByColumn, [[2], [1], [3]])
        XCTAssertEqual(l.focusedWindow, 2)
        var noWrap = testConfig
        noWrap.wrapsAround = false
        XCTAssertEqual(l.run(.move(.left), config: noWrap), l)
        let r = s.run(.move(.right))
        XCTAssertEqual(r.windowsByColumn, [[1], [3], [2]])
        XCTAssertEqual(s.run(.moveFirst).windowsByColumn, [[2], [1], [3]])
        XCTAssertEqual(s.run(.moveLast).windowsByColumn, [[1], [3], [2]])
    }

    func testMoveRespectsPins() {
        var s = makeStrip([1, 2, 3], focused: 1)
        s.columns[0].pin = .left
        var noWrap = testConfig
        noWrap.wrapsAround = false
        XCTAssertEqual(s.run(.move(.left), config: noWrap), s)
        XCTAssertEqual(s.run(.moveFirst), s)
        XCTAssertEqual(s.run(.focusFirst, .move(.right)).windowsByColumn, [[1], [2], [3]])
    }

    func testMoveUpDownInStack() {
        let s = Strip(columns: [Column(windows: [1, 2, 3], heightWeights: [1, 2, 3], activeIndex: 0, widthFraction: 0.5)])
        let d = s.run(.move(.down))
        XCTAssertEqual(d.columns[0].windows, [2, 1, 3])
        XCTAssertEqual(d.columns[0].heightWeights, [2, 1, 3])
        XCTAssertEqual(d.focusedWindow, 1)
        XCTAssertEqual(s.run(.move(.up)), s)
    }

    func testCycleWidthForwardBackwardWraps() {
        let s = makeStrip([1], width: 0.5)
        XCTAssertEqual(s.run(.cycleWidth).columns[0].widthFraction, 0.75)
        XCTAssertEqual(s.run(.cycleWidth, .cycleWidth).columns[0].widthFraction, 0.25)
        XCTAssertEqual(s.run(.cycleWidthBackward).columns[0].widthFraction, 0.25)
        XCTAssertEqual(s.run(.cycleWidthBackward, .cycleWidthBackward).columns[0].widthFraction, 0.75)
        let near = makeStrip([1], width: 0.505)
        XCTAssertEqual(near.run(.cycleWidth).columns[0].widthFraction, 0.75, "epsilon skips the current preset")
        var full = makeStrip([1], width: 0.5)
        full.columns[0].isFullWidth = true
        let cycled = full.run(.cycleWidth)
        XCTAssertFalse(cycled.columns[0].isFullWidth)
        XCTAssertEqual(cycled.columns[0].widthFraction, 0.25, "from effective 1.0 wraps to smallest")
        var noPresets = testConfig
        noPresets.widthPresets = []
        XCTAssertEqual(s.applying(.cycleWidth, area: testArea, config: noPresets), s)
    }

    func testFullWidthWiderNarrower() {
        let s = makeStrip([1], width: 0.5)
        let full = s.run(.toggleFullWidth)
        XCTAssertTrue(full.columns[0].isFullWidth)
        XCTAssertEqual(full.columns[0].effectiveWidthFraction, 1)
        XCTAssertEqual(full.run(.toggleFullWidth).columns[0].effectiveWidthFraction, 0.5)
        XCTAssertEqual(s.run(.wider).columns[0].widthFraction, 0.6, accuracy: 1e-9)
        XCTAssertEqual(s.run(.wider, .wider, .wider, .wider, .wider, .wider).columns[0].widthFraction, 1)
        XCTAssertEqual(makeStrip([1], width: 0.15).run(.narrower).columns[0].widthFraction, 0.1, accuracy: 1e-9)
        XCTAssertEqual(full.run(.narrower).columns[0].widthFraction, 0.9, accuracy: 1e-9)
        XCTAssertFalse(full.run(.narrower).columns[0].isFullWidth)
    }

    func testFullWidthOnlyLastsWhileFocused() {
        let s = makeStrip([1, 2, 3], focused: 1).run(.toggleFullWidth)
        XCTAssertTrue(s.columns[1].isFullWidth)
        let away = s.run(.focus(.left))
        XCTAssertFalse(away.columns[1].isFullWidth, "focus moved on → back to its own width")
        XCTAssertEqual(away.columns[1].widthFraction, 0.5)
        XCTAssertFalse(s.focusing(3).columns[1].isFullWidth, "clicking another window does the same")
        XCTAssertTrue(s.run(.move(.right)).columns[2].isFullWidth, "moving the column keeps it (still focused)")
        XCTAssertFalse(s.inserting(9, position: .afterFocused, widthFraction: 0.5, focus: true).columns[1].isFullWidth)
        XCTAssertTrue(s.inserting(9, position: .afterFocused, widthFraction: 0.5, focus: false).columns[1].isFullWidth)
        let wide = LayoutEngine.placements(away, context: LayoutContext(area: testArea, screenFrame: testScreen), config: testConfig)
        XCTAssertEqual(wide.first { $0.window == 2 }?.frame.width, 495)
    }

    func testTallerShorterEqualize() {
        let s = Strip(columns: [Column(windows: [1, 2, 3], widthFraction: 0.5)])
        let t = s.run(.taller)
        let shares = t.columns[0].heightWeights
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(shares[0], 1.0 / 3 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(shares[1], shares[2], accuracy: 1e-9)
        let max = s.run(.taller, .taller, .taller, .taller, .taller, .taller, .taller, .taller)
        XCTAssertEqual(max.columns[0].heightWeights[0], 0.8, accuracy: 1e-9)
        XCTAssertTrue(max.columns[0].heightWeights.allSatisfy { $0 >= 0.1 - 1e-9 })
        let min = s.run(.shorter, .shorter, .shorter, .shorter)
        XCTAssertEqual(min.columns[0].heightWeights[0], 0.1, accuracy: 1e-9)
        XCTAssertEqual(max.run(.equalizeHeights).columns[0].heightWeights, [1, 1, 1])
        XCTAssertEqual(makeStrip([1]).run(.taller), makeStrip([1]))
        var tabbed = s
        tabbed.columns[0].mode = .tabbed
        XCTAssertEqual(tabbed.run(.taller), tabbed)
        [t, max, min].forEach { assertInvariants($0) }
    }

    func testCentreColumnIsUnclamped() {
        let s = makeStrip([1, 2, 3], width: 0.25, focused: 0)
        let c = s.run(.centreColumn)
        // column 0 spans 0...242.5, scrollable width 1000 → offset = 121.25 - 500
        XCTAssertEqual(c.viewportOffset, 121.25 - 500, accuracy: 1e-9)
        var pinned = s
        pinned.columns[0].pin = .left
        XCTAssertEqual(pinned.run(.centreColumn), pinned)
    }

    func testPinLeftRightAndUnpin() {
        let s = makeStrip([1, 2, 3], focused: 1)
        let l = s.run(.pinLeft)
        XCTAssertEqual(l.windowsByColumn, [[2], [1], [3]])
        XCTAssertEqual(l.columns[0].pin, .left)
        XCTAssertEqual(l.focusedWindow, 2)
        let un = l.run(.pinLeft)
        XCTAssertNil(un.columns[0].pin)
        XCTAssertEqual(un.windowsByColumn, [[2], [1], [3]])
        let r = l.run(.focusColumn(3), .pinRight)
        XCTAssertEqual(r.columns.last?.pin, .right)
        XCTAssertEqual(r.columns.first?.pin, .left)
        let swapped = r.run(.focusFirst, .pinRight)
        XCTAssertEqual(swapped.windowsByColumn, [[1], [3], [2]])
        XCTAssertEqual(swapped.columns.last?.pin, .right)
        XCTAssertNil(swapped.columns[1].pin, "previous right pin released")
        XCTAssertTrue(swapped.columns.filter { $0.pin == .left }.isEmpty, "moved column loses its left pin")
        let replaceLeft = l.run(.focusColumn(3), .pinLeft)
        XCTAssertEqual(replaceLeft.windowsByColumn, [[3], [2], [1]])
        XCTAssertNil(replaceLeft.columns[1].pin)
        [l, un, r, swapped, replaceLeft].forEach { assertInvariants($0) }
    }

    func testStackIntoNeighbours() {
        let s = makeStrip([1, 2, 3], focused: 1)
        let left = s.run(.stackIntoLeft)
        XCTAssertEqual(left.windowsByColumn, [[1, 2], [3]])
        XCTAssertEqual(left.focusedWindow, 2)
        let right = s.run(.stackIntoRight)
        XCTAssertEqual(right.windowsByColumn, [[1], [3, 2]])
        XCTAssertEqual(right.focusedWindow, 2)
        XCTAssertEqual(makeStrip([1, 2], focused: 0).run(.stackIntoLeft), makeStrip([1, 2], focused: 0))
        let stack = Strip(columns: [Column(windows: [1], widthFraction: 0.5), Column(windows: [2, 3], activeIndex: 1, widthFraction: 0.5)],
                          focusedColumnIndex: 1)
        let moved = stack.run(.stackIntoLeft)
        XCTAssertEqual(moved.windowsByColumn, [[1, 3], [2]])
        XCTAssertEqual(moved.focusedColumnIndex, 0)
        [left, right, moved].forEach { assertInvariants($0) }
    }

    func testPopOut() {
        let s = Strip(columns: [Column(windows: [1, 2], activeIndex: 1, widthFraction: 0.4), Column(windows: [3], widthFraction: 0.5)])
        let r = s.run(.popOutRight)
        XCTAssertEqual(r.windowsByColumn, [[1], [2], [3]])
        XCTAssertEqual(r.focusedWindow, 2)
        XCTAssertEqual(r.columns[1].widthFraction, 0.4)
        let l = s.run(.popOutLeft)
        XCTAssertEqual(l.windowsByColumn, [[2], [1], [3]])
        XCTAssertEqual(l.focusedWindow, 2)
        XCTAssertEqual(makeStrip([1]).run(.popOutRight), makeStrip([1]))
        var pinned = s
        pinned.columns[0].pin = .left
        XCTAssertEqual(pinned.run(.popOutLeft).windowsByColumn, [[1], [2], [3]], "can't pop out past a left pin")
        [r, l, pinned.run(.popOutLeft)].forEach { assertInvariants($0) }
    }

    func testToggleTabbedAndNonStripCommands() {
        let s = makeStrip([1, 2])
        XCTAssertEqual(s.run(.toggleTabbed).columns[0].mode, .tabbed)
        XCTAssertEqual(s.run(.toggleTabbed, .toggleTabbed).columns[0].mode, .stacked)
        for c in [Command.toggleFloat, .sendToNextDisplay, .toggleEnabled, .gatherWindows, .showIndicator, .openSettings] {
            XCTAssertEqual(s.run(c), s)
            XCTAssertFalse(c.isStripCommand)
        }
        XCTAssertEqual(Strip().run(.focus(.right)), Strip())
    }

    func testRandomCommandSequencesKeepInvariants() {
        var generator = SplitMix(seed: 42)
        let commands = Command.allCases.filter(\.isStripCommand)
        for _ in 0..<200 {
            var s = makeStrip([1, 2, 3, 4, 5], focused: 2)
            var next: WindowID = 10
            for _ in 0..<60 {
                switch generator.next() % 10 {
                case 0:
                    s = s.inserting(next, position: .afterFocused, widthFraction: 0.5, focus: generator.next() % 2 == 0)
                    next += 1
                case 1:
                    if let w = s.allWindows.randomElement(using: &generator) { s = s.removing(w) }
                default:
                    s = s.run(commands[Int(generator.next() % UInt64(commands.count))])
                }
                assertInvariants(s)
            }
        }
    }
}

/// Deterministic RNG for property tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
