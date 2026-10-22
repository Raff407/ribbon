import CoreGraphics
import XCTest
@testable import RibbonCore

final class SettingsCodingTests: XCTestCase {
    func decode(_ json: String) throws -> RibbonSettings {
        try JSONDecoder().decode(RibbonSettings.self, from: Data(json.utf8))
    }

    func testEmptyJSONGivesDefaults() throws {
        XCTAssertEqual(try decode("{}"), RibbonSettings.defaults)
    }

    func testPartialJSONKeepsOtherDefaults() throws {
        let s = try decode(#"{"layout":{"gap":20,"centreMode":"always"},"behavior":{"focusFollowsMouse":true},"unknownKey":5}"#)
        XCTAssertEqual(s.layout.gap, 20)
        XCTAssertEqual(s.layout.centreMode, .always)
        XCTAssertEqual(s.layout.outerGap, LayoutConfig.default.outerGap)
        XCTAssertTrue(s.behavior.focusFollowsMouse)
        XCTAssertEqual(s.behavior.reconcileInterval, BehaviorSettings().reconcileInterval)
        XCTAssertEqual(s.bindings, DefaultBindings.all)
    }

    func testMalformedFieldsFallBack() throws {
        let s = try decode(#"{"layout":{"gap":"wide"},"animation":{"speed":2,"spring":{"stiffness":"x"}},"appearance":7,"trackpad":{"swipeFingers":4}}"#)
        XCTAssertEqual(s.layout.gap, LayoutConfig.default.gap)
        XCTAssertEqual(s.animation.speed, 2)
        XCTAssertEqual(s.animation.spring, .default)
        XCTAssertEqual(s.appearance, AppearanceSettings())
        XCTAssertEqual(s.trackpad.swipeFingers, 4)
        XCTAssertEqual(s.trackpad.scrollModifiers, .hyperLite)
    }

    func testUnknownCommandBindingsAreSkipped() throws {
        let s = try decode(#"{"bindings":[{"command":"focus-left","combo":{"keyCode":4,"modifiers":3}},{"command":"teleport","combo":{"keyCode":1,"modifiers":3}},{"bogus":true}],"rules":[{"bundleID":"a","appName":"A","action":"float"},{"bundleID":"b","appName":"B","action":"explode"}]}"#)
        XCTAssertEqual(s.bindings, [KeyBinding(command: .focus(.left), combo: KeyCombo(keyCode: 4, modifiers: .hyperLite))])
        XCTAssertEqual(s.rules.map(\.bundleID), ["a"])
    }

    func testUntouchedOldDefaultsMoveToTheOptionSet() throws {
        var old = RibbonSettings.defaults
        old.bindings = DefaultBindings.preset(.controlOption)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["bindingsRevision"] = nil
        let loaded = try JSONDecoder().decode(RibbonSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.bindings, DefaultBindings.all)
        XCTAssertEqual(loaded.bindingsRevision, RibbonSettings.currentBindingsRevision)
    }

    func testChosenControlOptionPresetIsKept() throws {
        var chosen = RibbonSettings.defaults
        chosen.bindings = DefaultBindings.preset(.controlOption)
        let loaded = try JSONDecoder().decode(RibbonSettings.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(loaded.bindings, DefaultBindings.preset(.controlOption), "revision 2 → a deliberate choice")
    }

    func testOptionPresetAvoidsArrowsDigitsAndDeadKeys() {
        let reserved: Set<UInt32> = Set(KeyCode.digits + [KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow,
                                                          KeyCode.e, KeyCode.u, KeyCode.i, KeyCode.n, KeyCode.grave, KeyCode.space])
        for binding in DefaultBindings.preset(.option) {
            XCTAssertFalse(reserved.contains(binding.combo.keyCode), "\(binding.command.id) uses a reserved key")
            XCTAssertTrue(binding.combo.modifiers.subtracting(.shift) == .option, "\(binding.command.id) isn't an ⌥ shortcut")
        }
        XCTAssertTrue(RibbonSettings(bindings: DefaultBindings.preset(.controlOption)).conflictingCombos.isEmpty)
        XCTAssertFalse(ShortcutPreset.option.title.isEmpty)
    }

    func testRoundTrip() throws {
        var s = RibbonSettings.defaults
        s.layout.widthPresets = [0.4, 0.8]
        s.rules = [AppRule(bundleID: "com.x", appName: "X", action: .ignore)]
        s.disabledDisplays = ["uuid"]
        s.trackpad.scrollModifiers = [.command, .shift]
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(RibbonSettings.self, from: data), s)
    }

    func testDefaultBindingsHaveNoConflicts() {
        XCTAssertTrue(RibbonSettings.defaults.conflictingCombos.isEmpty)
        var s = RibbonSettings.defaults
        s.bindings.append(KeyBinding(command: .wider, combo: KeyCombo(keyCode: KeyCode.h, modifiers: .option)))
        XCTAssertEqual(s.conflictingCombos, [KeyCombo(keyCode: KeyCode.h, modifiers: .option)])
        XCTAssertEqual(ModifierSet([.command, .shift, .control, .option]).symbols, "⌃⌥⇧⌘")
        XCTAssertEqual(AnimationSettings(speed: 2).effectiveSpring.stiffness, 4800)
    }
}

final class CommandTests: XCTestCase {
    func testIDsRoundTripAndAreUnique() throws {
        let ids = Command.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for c in Command.allCases {
            XCTAssertEqual(Command(id: c.id), c)
            XCTAssertFalse(c.title.isEmpty)
            _ = c.category
            let data = try JSONEncoder().encode(c)
            XCTAssertEqual(try JSONDecoder().decode(Command.self, from: data), c)
        }
        XCTAssertNil(Command(id: "nope"))
        XCTAssertThrowsError(try JSONDecoder().decode(Command.self, from: Data(#""nope""#.utf8)))
        XCTAssertEqual(Command.focusColumn(3).id, "focus-column-3")
        XCTAssertEqual(Command.allCases.count, 43)
    }

    func testCategories() {
        XCTAssertEqual(Command.focus(.left).category, .navigate)
        XCTAssertEqual(Command.wider.category, .size)
        XCTAssertEqual(Command.toggleTabbed.category, .stacks)
        XCTAssertEqual(Command.openSettings.category, .general)
    }
}

final class GeometryTests: XCTestCase {
    func testFlipIsInvolution() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flipped = CoordinateSpace.flip(r, primaryHeight: 1000)
        XCTAssertEqual(flipped, CGRect(x: 10, y: 780, width: 300, height: 200))
        XCTAssertEqual(CoordinateSpace.flip(flipped, primaryHeight: 1000), r)
        XCTAssertEqual(CoordinateSpace.flip(CGPoint(x: 5, y: 100), primaryHeight: 1000), CGPoint(x: 5, y: 900))
    }

    func testRectHelpers() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(r.center, CGPoint(x: 50, y: 50))
        XCTAssertTrue(r.isApproximatelyEqual(to: CGRect(x: 1, y: -1, width: 102, height: 99)))
        XCTAssertFalse(r.isApproximatelyEqual(to: CGRect(x: 5, y: 0, width: 100, height: 100)))
        XCTAssertEqual(r.intersectionArea(with: CGRect(x: 50, y: 50, width: 100, height: 100)), 2500)
        XCTAssertEqual(r.intersectionArea(with: CGRect(x: 500, y: 0, width: 1, height: 1)), 0)
        XCTAssertEqual(CGRect(x: 0.4, y: 0.6, width: 10.5, height: 9.4).roundedToPoints, CGRect(x: 0, y: 1, width: 11, height: 9))
        XCTAssertEqual(Side.left.opposite, .right)
    }

    func testColumnAndStripBasics() {
        let c = Column(windows: [1, 2], activeIndex: 5, widthFraction: 0.5)
        XCTAssertNil(c.activeWindow)
        XCTAssertEqual(Strip(columns: [c], focusedColumnIndex: nil).focusedColumnIndex, 0)
        XCTAssertNil(Strip(columns: [], focusedColumnIndex: 3).focusedColumnIndex)
        XCTAssertEqual(makeStrip([1, 2]).location(of: 2), WindowLocation(column: 1, row: 0))
        XCTAssertNil(Strip().focusedColumn)
    }
}
