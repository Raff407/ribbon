import CoreGraphics
import Foundation
import XCTest
import RibbonCore
@testable import RibbonEngine

/// Opt in with RIBBON_RUN_LAYOUT_BENCHMARK=1 Scripts/swiftw test -c release
/// --filter LayoutBenchmarkTests. Prints medians rather than imposing timing thresholds.
/// Copy this file and Fakes.swift to the baseline checkout to compare identical workloads.
final class LayoutBenchmarkTests: XCTestCase {
    func testTabbedRelayoutBenchmark() throws {
        guard ProcessInfo.processInfo.environment["RIBBON_RUN_LAYOUT_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in release benchmark; no Accessibility or real windows are used")
        }
        for columnCount in [20, 100, 300] {
            let h = Harness().start()
            h.applier.recordsApplications = false
            var columns: [Column] = []
            for index in 0..<columnCount {
                let first = WindowID(index * 3 + 1)
                let windows: [WindowID] = [first, first + 1, first + 2]
                columns.append(Column(windows: windows, widthFraction: 0.3, mode: .tabbed))
            }
            for column in columns {
                for id in column.windows { h.manager.infos[id] = h.win(id) }
            }
            h.manager.focusedWindowID = 1
            let iterations = 300
            var samples: [Double] = []
            var checksum = 0.0
            for sample in 0..<6 {
                let start = ProcessInfo.processInfo.systemUptime
                for tick in 0..<iterations {
                    h.manager.world = World(strips: [h.key: Strip(columns: columns, viewportOffset: Double(tick % 200))])
                    h.manager.relayout(animated: false)
                    // Reap cancelled save tasks and avoid retaining an artificial history.
                    h.scheduler.advance(by: 0)
                    checksum += Double(h.applier.expected[1]?.minX ?? 0)
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if sample > 0 { samples.append(elapsed * 1_000_000 / Double(iterations)) }
            }
            let median = samples.sorted()[samples.count / 2]
            print("RIBBON_LAYOUT_BENCHMARK columns=\(columnCount) windows=\(columnCount * 3) median_us=\(String(format: "%.3f", median)) checksum=\(checksum)")
            XCTAssertNotEqual(checksum, 0)
        }
    }
}
