import XCTest
import RibbonCore
@testable import RibbonInput

final class HotkeyTapStateTests: XCTestCase {
    private let combo = KeyCombo(keyCode: KeyCode.h, modifiers: .option)

    func testSuspendingReleasesModifierHoldAndPassesKeysThrough() {
        let state = HotkeyTapState()
        state.update(table: [combo: .focus(.left)], holdModifiers: .option)
        XCTAssertEqual(state.holdTransition(for: .option)?.held, true)
        var holds: [Bool] = []
        state.onHold = { holds.append($0) }

        state.setSuspended(true)

        XCTAssertEqual(holds, [false])
        XCTAssertNil(state.holdTransition(for: .option))
        XCTAssertNil(state.command(forKeyCode: combo.keyCode, modifiers: .option, isRepeat: false))
        state.setSuspended(false)
        XCTAssertEqual(state.holdTransition(for: .option)?.held, true)
    }

    func testUnregisteringReleasesHold() {
        let state = HotkeyTapState()
        state.update(table: [combo: .focus(.left)], holdModifiers: .option)
        XCTAssertEqual(state.holdTransition(for: .option)?.held, true)
        var holds: [Bool] = []
        state.onHold = { holds.append($0) }

        state.update(table: [:], holdModifiers: [])

        XCTAssertEqual(holds, [false])
        XCTAssertNil(state.holdTransition(for: .option))
    }

    func testIdenticalRegistrationPreservesHold() {
        let state = HotkeyTapState()
        state.update(table: [combo: .focus(.left)], holdModifiers: .option)
        XCTAssertEqual(state.holdTransition(for: .option)?.held, true)
        var holds: [Bool] = []
        state.onHold = { holds.append($0) }

        state.update(table: [combo: .focus(.left)], holdModifiers: .option)

        XCTAssertTrue(holds.isEmpty)
        XCTAssertNil(state.holdTransition(for: .option))
    }

    func testQueuedCommandDoesNotFireAfterSuspendingAndResuming() throws {
        let state = HotkeyTapState()
        state.update(table: [combo: .focus(.left)], holdModifiers: .option)
        let match = try XCTUnwrap(state.command(forKeyCode: combo.keyCode, modifiers: .option, isRepeat: false))
        var commands: [Command] = []
        state.onCommand = { commands.append($0) }
        state.dispatch(match.command, generation: match.generation)

        state.setSuspended(true)
        state.setSuspended(false)

        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(commands.isEmpty)
    }

    func testQueuedHoldDoesNotReappearAfterUnregistering() throws {
        let state = HotkeyTapState()
        state.update(table: [combo: .focus(.left)], holdModifiers: .option)
        let transition = try XCTUnwrap(state.holdTransition(for: .option))
        var holds: [Bool] = []
        state.onHold = { holds.append($0) }
        state.dispatchHold(transition.held, generation: transition.generation)

        state.update(table: [:], holdModifiers: [])

        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(holds, [false])
    }

    func testStoppedStatePassesKeysThrough() {
        let state = HotkeyTapState()
        state.update(table: [combo: .focus(.left)], holdModifiers: .option)
        state.stop()

        XCTAssertNil(state.command(forKeyCode: combo.keyCode, modifiers: .option, isRepeat: false))
        XCTAssertNil(state.holdTransition(for: .option))
    }

    func testQueuedReleaseStillReleasesDisplayedHoldWhenSuspended() throws {
        try assertQueuedReleaseSurvivesReset { $0.setSuspended(true) }
    }

    func testQueuedReleaseStillReleasesDisplayedHoldWhenUnregistered() throws {
        try assertQueuedReleaseSurvivesReset { $0.update(table: [:], holdModifiers: []) }
    }

    private func assertQueuedReleaseSurvivesReset(_ reset: (HotkeyTapState) -> Void) throws {
        let state = HotkeyTapState()
        state.update(table: [combo: .focus(.left)], holdModifiers: .option)
        var holds: [Bool] = []
        state.onHold = { holds.append($0) }
        let press = try XCTUnwrap(state.holdTransition(for: .option))
        state.dispatchHold(press.held, generation: press.generation)
        let pressed = expectation(description: "hold delivered")
        DispatchQueue.main.async { pressed.fulfill() }
        wait(for: [pressed], timeout: 2)
        XCTAssertEqual(holds, [true])

        let release = try XCTUnwrap(state.holdTransition(for: []))
        state.dispatchHold(release.held, generation: release.generation)
        reset(state)

        let released = expectation(description: "release queue drained")
        DispatchQueue.main.async { released.fulfill() }
        wait(for: [released], timeout: 2)
        XCTAssertEqual(holds, [true, false])
    }

    func testCarbonHoldTrackerUsesConfiguredModifiers() {
        let tracker = ModifierHoldTracker(prefix: .option)
        let (held, transition) = tracker.updated(with: [.option, .shift])
        XCTAssertEqual(transition, true)
        XCTAssertTrue(held.isHeld)
        XCTAssertEqual(held.updated(with: .control).1, false)
        XCTAssertNil(ModifierHoldTracker(prefix: []).updated(with: .option).1)
    }

    func testPrimaryModifierTieIsDeterministic() {
        let option = KeyBinding(command: .focus(.left), combo: combo)
        let control = KeyBinding(command: .focus(.right), combo: KeyCombo(keyCode: KeyCode.l, modifiers: .control))
        XCTAssertEqual(EventTapHotkeyManager.primaryModifiers(of: [option, control]), .control)
        XCTAssertEqual(EventTapHotkeyManager.primaryModifiers(of: [control, option]), .control)
    }
}
