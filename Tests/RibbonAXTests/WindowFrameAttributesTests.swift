import ApplicationServices
import XCTest
@testable import RibbonAX

final class WindowFrameAttributesTests: XCTestCase {
    func testParsesFrameAndFullscreenFromSameSnapshot() throws {
        let origin = CGPoint(x: -1_200, y: 30)
        let size = CGSize(width: 900, height: 700)
        let values: [String: CFTypeRef] = [
            kAXPositionAttribute: try XCTUnwrap(AXValueConversion.value(origin)),
            kAXSizeAttribute: try XCTUnwrap(AXValueConversion.value(size)),
            AXAttributeName.fullScreen: kCFBooleanTrue,
        ]
        let attributes = WindowFrameAttributes.parse(values)
        XCTAssertEqual(attributes.frame, CGRect(origin: origin, size: size))
        XCTAssertEqual(attributes.isFullscreen, true)
    }

    func testUnavailableFullscreenStateIsNotAnExit() {
        XCTAssertNil(WindowFrameAttributes.parse([:]).isFullscreen)
        XCTAssertEqual(WindowFrameAttributes.parse([AXAttributeName.fullScreen: kCFBooleanFalse]).isFullscreen, false)
    }

    func testPartialFrameRemainsUnknown() throws {
        let attributes = WindowFrameAttributes.parse([
            kAXPositionAttribute: try XCTUnwrap(AXValueConversion.value(CGPoint(x: 10, y: 20))),
            AXAttributeName.fullScreen: kCFBooleanTrue,
        ])
        XCTAssertNil(attributes.frame)
        XCTAssertEqual(attributes.isFullscreen, true)
    }
}
