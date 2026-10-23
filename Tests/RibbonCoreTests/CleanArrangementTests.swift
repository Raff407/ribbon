import CoreGraphics
import XCTest
@testable import RibbonCore

/// With `showsPartialColumns` off (the default), every window on screen fits entirely
/// and no two overlap.
final class CleanArrangementTests: XCTestCase {
    private var config: LayoutConfig {
        var config = testConfig
        config.showsPartialColumns = false
        return config
    }

    private let context = LayoutContext(area: testArea, screenFrame: testScreen)

    private func strip(_ widths: [Double], focused: Int = 0, offset: Double = 0) -> Strip {
        let columns = widths.enumerated().map { Column(windows: [WindowID($0.offset + 1)], widthFraction: $0.element) }
        return Strip(columns: columns, focusedColumnIndex: focused, viewportOffset: offset)
    }

    func testPartialColumnsAreOffByDefault() throws {
        XCTAssertFalse(LayoutConfig.default.showsPartialColumns)
        let decoded = try JSONDecoder().decode(LayoutConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.showsPartialColumns)
    }

    func testWindowThatOnlyPartlyFitsIsParkedNotCutOff() {
        // 495 + 242.5 fit; the third column would hang 252.5pt off the right edge.
        let p = LayoutEngine.placements(strip([0.5, 0.25, 0.5]), context: context, config: config)
        XCTAssertEqual(p.map(\.visibility), [.visible, .visible, .hidden(.right)])
    }

    func testScrollingRightParksTheWindowLeavingOnTheLeft() {
        let revealed = LayoutEngine.revealFocused(strip([0.5, 0.25, 0.5], focused: 2), area: testArea, config: config)
        let p = LayoutEngine.placements(revealed, context: context, config: config)
        XCTAssertEqual(p.map(\.visibility), [.hidden(.left), .visible, .visible])
        XCTAssertEqual(p[2].frame.maxX, testArea.maxX, "focused window ends flush with the edge")
    }

    func testScrollPositionMovesToFillTheScreenInsteadOfLeavingAGap() {
        // Left over from a wider third column: only window 2 fits at offset 250, and
        // window 1 (cut off on the left) is parked, leaving a gap.
        let stranded = strip([0.5, 1.0 / 3, 0.5], focused: 1, offset: 250)
        let revealed = LayoutEngine.revealFocused(stranded, area: testArea, config: config)
        let p = LayoutEngine.placements(revealed, context: context, config: config)
        XCTAssertEqual(p.filter { $0.visibility == .visible }.count, 2)
        XCTAssertEqual(LayoutEngine.revealFocused(revealed, area: testArea, config: config), revealed, "already as full as it gets")
    }

    func testFillingTheScreenNeverHidesTheFocusedWindow() {
        for offset in stride(from: 0.0, through: 900, by: 50) {
            for focus in 0..<4 {
                let s = LayoutEngine.revealFocused(strip([0.4, 0.3, 0.6, 0.35], focused: focus, offset: offset), area: testArea, config: config)
                let focused = LayoutEngine.placements(s, context: context, config: config)[focus]
                XCTAssertEqual(focused.visibility, .visible, "offset \(offset) focus \(focus)")
            }
        }
    }

    func testPeekModeStillShowsCutOffNeighbours() {
        var peek = config
        peek.showsPartialColumns = true
        let p = LayoutEngine.placements(strip([0.5, 0.25, 0.5]), context: context, config: peek)
        XCTAssertEqual(p[2].visibility, .partial)
    }

    func testNoShownWindowHangsOffScreenOrOverlapsAnother() {
        let layouts: [[Double]] = [
            [0.5, 1.0 / 3, 0.5], [2.0 / 3, 0.5, 0.25], [0.25, 0.25, 0.75, 0.5],
            [0.45, 0.45, 0.45, 0.45], [1.0 / 3, 1.0 / 3, 1.0 / 3, 2.0 / 3, 0.5],
        ]
        for mode in CentreMode.allCases {
            var config = config
            config.centreMode = mode
            for widths in layouts {
                for focus in widths.indices {
                    let revealed = LayoutEngine.revealFocused(strip(widths, focused: focus), area: testArea, config: config)
                    assertClean(LayoutEngine.placements(revealed, context: context, config: config), "\(mode) \(widths) focus \(focus)")
                }
            }
        }
    }

    private func assertClean(_ placements: [WindowPlacement], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = placements.filter { !$0.visibility.isHidden }
        XCTAssertTrue(shown.contains { $0.isFocused }, "focus is on screen: \(label)", file: file, line: line)
        for p in shown where !p.isFocused {
            XCTAssertEqual(p.visibility, .visible, label, file: file, line: line)
            XCTAssertGreaterThanOrEqual(p.frame.minX, testArea.minX - 1, "off the left edge: \(label)", file: file, line: line)
            XCTAssertLessThanOrEqual(p.frame.maxX, testArea.maxX + 1, "off the right edge: \(label)", file: file, line: line)
        }
        for (i, a) in shown.enumerated() {
            for b in shown[(i + 1)...] {
                XCTAssertFalse(a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.frame), "overlap: \(label)", file: file, line: line)
            }
        }
    }
}

private extension Visibility {
    var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }
}
