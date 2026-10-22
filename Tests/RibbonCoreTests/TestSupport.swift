import CoreGraphics
import XCTest
@testable import RibbonCore

let testConfig = LayoutConfig(gap: 10, outerGap: 0, centreMode: .never, widthPresets: [0.25, 0.5, 0.75],
                              defaultWidthFraction: 0.5, widthStep: 0.1, heightStep: 0.1, minWidthFraction: 0.1,
                              parkingSliver: 1, tabBarHeight: 20)
/// 1000 × 800 working area at the origin.
let testArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
let testScreen = CGRect(x: 0, y: 0, width: 1000, height: 800)

/// A strip with one single-window column per id (ids double as column order).
func makeStrip(_ ids: [WindowID], width: Double = 0.5, focused: Int = 0, offset: Double = 0) -> Strip {
    Strip(columns: ids.map { Column(windows: [$0], widthFraction: width) }, focusedColumnIndex: focused, viewportOffset: offset)
}

func assertInvariants(_ strip: Strip, file: StaticString = #filePath, line: UInt = #line) {
    if strip.columns.isEmpty {
        XCTAssertNil(strip.focusedColumnIndex, "empty strip has focus", file: file, line: line)
        return
    }
    guard let f = strip.focusedColumnIndex else { return XCTFail("missing focus", file: file, line: line) }
    XCTAssertTrue(strip.columns.indices.contains(f), "focus out of range", file: file, line: line)
    let all = strip.allWindows
    XCTAssertEqual(Set(all).count, all.count, "duplicate window", file: file, line: line)
    for (i, column) in strip.columns.enumerated() {
        XCTAssertFalse(column.windows.isEmpty, "empty column \(i)", file: file, line: line)
        XCTAssertEqual(column.windows.count, column.heightWeights.count, "weights mismatch \(i)", file: file, line: line)
        XCTAssertTrue(column.heightWeights.allSatisfy { $0 > 0 }, "non-positive weight \(i)", file: file, line: line)
        XCTAssertTrue(column.windows.indices.contains(column.activeIndex), "activeIndex \(i)", file: file, line: line)
        if column.pin == .left { XCTAssertEqual(i, 0, "left pin not first", file: file, line: line) }
        if column.pin == .right { XCTAssertEqual(i, strip.columns.count - 1, "right pin not last", file: file, line: line) }
    }
}

extension Strip {
    func run(_ commands: Command..., area: CGRect = testArea, config: LayoutConfig = testConfig) -> Strip {
        commands.reduce(self) { $0.applying($1, area: area, config: config) }
    }

    var windowsByColumn: [[WindowID]] { columns.map(\.windows) }
}

func info(_ id: WindowID, pid: ProcessID = 1, bundle: String? = "com.test.app", title: String = "Window",
          frame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300), subrole: String? = "AXStandardWindow",
          resizable: Bool = true) -> WindowInfo {
    WindowInfo(id: id, pid: pid, bundleID: bundle, appName: "App", title: title, frame: frame,
               subrole: subrole, isResizable: resizable)
}
