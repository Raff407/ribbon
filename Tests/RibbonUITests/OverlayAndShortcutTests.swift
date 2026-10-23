import AppKit
import XCTest
import RibbonCore
@testable import RibbonUI

final class OverlayAndShortcutTests: XCTestCase {
    private func model() -> TabBarModel {
        TabBarModel(frame: CGRect(x: 0, y: 0, width: 400, height: 30), tabs: [
            .init(window: 1, title: "First", appName: "Editor", bundleID: "example.editor"),
            .init(window: 2, title: "Second", appName: "Editor", bundleID: "example.editor"),
        ], activeIndex: 0)
    }

    // `needsDisplay` can't be observed on a view outside a window (AppKit reports false),
    // so these check the redraw decision itself.
    private func needsRedraw(_ change: (inout TabBarModel) -> Void) -> Bool {
        let old = model()
        var new = old
        change(&new)
        return TabBarView.needsRedraw(.init(model: new, icons: []), after: .init(model: old, icons: []))
    }

    func testMovingTabBarDoesNotRedrawUnchangedContents() {
        XCTAssertFalse(needsRedraw { $0.frame.origin.x = 100 })
        XCTAssertFalse(needsRedraw { _ in })
    }

    func testResizingTabBarRedrawsContents() {
        XCTAssertTrue(needsRedraw { $0.frame.size.width = 600 })
    }

    func testChangingTitleOrActiveTabRedrawsContents() {
        XCTAssertTrue(needsRedraw { $0.tabs[0].title = "Renamed" })
        XCTAssertTrue(needsRedraw { $0.activeIndex = 1 })
    }

    func testNewIconsRedrawContents() {
        let old = TabBarView.Content(model: model(), icons: [])
        let new = TabBarView.Content(model: model(), icons: [NSImage()])
        XCTAssertTrue(TabBarView.needsRedraw(new, after: old))
    }

    func testReleasingActiveRecorderResumesGlobalShortcuts() {
        var suspensions: [Bool] = []
        var recorder: ShortcutRecorderCoordinator? = .init { suspensions.append($0) }
        recorder?.start(.new(.focus(.left))) { _ in XCTFail("Deinit must not commit a recording") }

        recorder = nil

        XCTAssertEqual(suspensions, [true, false])
    }
}
