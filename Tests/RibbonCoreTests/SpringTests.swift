import CoreGraphics
import XCTest
@testable import RibbonCore

final class SpringTests: XCTestCase {
    func simulate(_ params: SpringParameters, dt: Double, steps: Int, from: Double = 0, to: Double = 100) -> [SpringState] {
        var state = SpringState(position: from)
        var out: [SpringState] = []
        for _ in 0..<steps {
            state = Spring.step(state, target: to, parameters: params, dt: dt)
            out.append(state)
        }
        return out
    }

    func testCriticallyDampedConvergesMonotonically() {
        let states = simulate(.default, dt: 1.0 / 120, steps: 240)
        for (a, b) in zip(states, states.dropFirst()) { XCTAssertGreaterThanOrEqual(b.position, a.position - 1e-9) }
        XCTAssertTrue(states.allSatisfy { $0.position <= 100 + 1e-9 }, "no overshoot")
        XCTAssertTrue(Spring.isSettled(states.last!, target: 100))
    }

    func testLargeStepIsStable() {
        for params in [SpringParameters.default, SpringParameters(stiffness: 600, dampingRatio: 0.5), SpringParameters(stiffness: 600, dampingRatio: 2)] {
            let s = Spring.step(SpringState(position: 0, velocity: 5000), target: 100, parameters: params, dt: 1)
            XCTAssertTrue(s.position.isFinite && s.velocity.isFinite)
            XCTAssertEqual(s.position, 100, accuracy: 1)
        }
    }

    func testUnderAndOverDamped() {
        let under = simulate(SpringParameters(stiffness: 400, dampingRatio: 0.3), dt: 1.0 / 60, steps: 600)
        XCTAssertGreaterThan(under.map(\.position).max()!, 100, "underdamped overshoots")
        XCTAssertEqual(under.last!.position, 100, accuracy: 0.5)
        let over = simulate(SpringParameters(stiffness: 400, dampingRatio: 3), dt: 1.0 / 60, steps: 1200)
        XCTAssertLessThanOrEqual(over.map(\.position).max()!, 100 + 1e-6)
        XCTAssertEqual(over.last!.position, 100, accuracy: 0.5)
    }

    func testDegenerateParameters() {
        let s = SpringState(position: 3, velocity: 2)
        XCTAssertEqual(Spring.step(s, target: 10, parameters: .default, dt: 0), s)
        XCTAssertEqual(Spring.step(s, target: 10, parameters: SpringParameters(stiffness: 0), dt: 0.1), SpringState(position: 10))
        XCTAssertEqual(SpringParameters.default.withSpeed(2).stiffness, 4800)
    }

    func testOriginSpringRetargetKeepsVelocity() {
        var spring = OriginSpring(from: .zero, to: CGPoint(x: 100, y: 50))
        for _ in 0..<5 { spring = spring.stepped(dt: 1.0 / 60, parameters: .default) }
        let velocity = spring.x.velocity
        XCTAssertGreaterThan(velocity, 0)
        let retargeted = spring.retargeted(to: CGPoint(x: -100, y: 0))
        XCTAssertEqual(retargeted.x.velocity, velocity)
        XCTAssertEqual(retargeted.origin, spring.origin)
        XCTAssertFalse(retargeted.isSettled)
        var settled = retargeted
        for _ in 0..<600 { settled = settled.stepped(dt: 1.0 / 60, parameters: .default) }
        XCTAssertTrue(settled.isSettled)
        XCTAssertEqual(settled.origin.x, -100, accuracy: 0.5)
    }
}
