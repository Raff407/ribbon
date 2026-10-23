import XCTest
@testable import RibbonInput

final class MultitouchSummaryTests: XCTestCase {
    func testSummaryAveragesOnlyTouchesOnSurface() {
        var touches = [touch(state: 3, x: 0.2, y: 0.4), touch(state: 4, x: 0.6, y: 0.8),
                       touch(state: 5, x: 1, y: 1)]
        let summary = touches.withUnsafeMutableBytes { bytes in
            MultitouchRouter.summarize(device: UnsafeMutableRawPointer(bitPattern: 12),
                                      touches: bytes.baseAddress, count: 3, timestamp: 1.5)
        }
        XCTAssertEqual(summary.device, 12)
        XCTAssertEqual(summary.fingerCount, 2)
        XCTAssertEqual(summary.meanX, 0.4, accuracy: 0.000001)
        XCTAssertEqual(summary.meanY, 0.6, accuracy: 0.000001)
        XCTAssertEqual(summary.time, 1.5)
    }

    func testSummaryOfReleasedTouchesIsEmpty() {
        var touches = [touch(state: 5, x: 0.4, y: 0.6)]
        let summary = touches.withUnsafeMutableBytes { bytes in
            MultitouchRouter.summarize(device: nil, touches: bytes.baseAddress, count: 1, timestamp: 2)
        }
        XCTAssertEqual(summary, TouchFrame(device: 0, fingerCount: 0, meanX: 0, meanY: 0, time: 2))
    }

    private func touch(state: Int32, x: Float, y: Float) -> MTTouch {
        let zero = MTPoint(x: 0, y: 0)
        return MTTouch(frame: 0, timestamp: 0, identifier: 1, state: state, foo3: 0, foo4: 0,
                       normalized: MTVector(position: MTPoint(x: x, y: y), velocity: zero),
                       size: 0, zero1: 0, angle: 0, majorAxis: 0, minorAxis: 0,
                       millimeters: MTVector(position: zero, velocity: zero), zero2: (0, 0), unk2: 0)
    }
}
