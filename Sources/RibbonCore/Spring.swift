import CoreGraphics
import Foundation

/// Spring parameters. Ribbon uses a critically damped spring by default (no overshoot:
/// overshooting real windows through the Accessibility API looks janky).
public struct SpringParameters: Equatable, Codable, Sendable {
    /// Angular frequency-ish stiffness (k with mass 1). Higher = faster.
    public var stiffness: Double
    /// Damping ratio; 1 = critically damped, < 1 overshoots, > 1 is sluggish.
    public var dampingRatio: Double

    /// 1200 with critical damping settles a typical column scroll in about a quarter of a
    /// second — quick enough to feel immediate, slow enough to follow.
    public init(stiffness: Double = 1200, dampingRatio: Double = 1) {
        self.stiffness = stiffness
        self.dampingRatio = dampingRatio
    }

    public static let `default` = SpringParameters()

    /// Scales stiffness for a user "speed" multiplier (1 = default). Speed 2 settles in
    /// about half the time (stiffness scales with speed²).
    public func withSpeed(_ speed: Double) -> SpringParameters {
        SpringParameters(stiffness: stiffness * speed * speed, dampingRatio: dampingRatio)
    }
}

public struct SpringState: Equatable, Sendable {
    public var position: Double
    public var velocity: Double

    public init(position: Double, velocity: Double = 0) {
        self.position = position
        self.velocity = velocity
    }
}

public enum Spring {
    /// Advances the spring by `dt` seconds towards `target`. Must be stable for any dt
    /// (use the closed-form solution for the critically/over/under-damped cases rather
    /// than explicit Euler), so a dropped frame never makes windows explode.
    public static func step(_ state: SpringState, target: Double, parameters: SpringParameters, dt: Double) -> SpringState {
        guard dt > 0 else { return state }
        guard parameters.stiffness > 0 else { return SpringState(position: target, velocity: 0) }
        let omega = parameters.stiffness.squareRoot()
        let zeta = max(0, parameters.dampingRatio)
        let x0 = state.position - target
        let v0 = state.velocity
        let (x, v): (Double, Double)
        if abs(zeta - 1) < 1e-6 {
            let b = v0 + omega * x0
            let decay = exp(-omega * dt)
            x = (x0 + b * dt) * decay
            v = (v0 - omega * b * dt) * decay
        } else if zeta < 1 {
            let a = zeta * omega
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-a * dt)
            let c = cos(wd * dt), s = sin(wd * dt)
            x = decay * (x0 * c + (v0 + a * x0) / wd * s)
            v = decay * (v0 * c - (a * v0 + omega * omega * x0) / wd * s)
        } else {
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -omega * (zeta - root)
            let r2 = -omega * (zeta + root)
            let c2 = (v0 - r1 * x0) / (r2 - r1)
            let c1 = x0 - c2
            let e1 = exp(r1 * dt), e2 = exp(r2 * dt)
            x = c1 * e1 + c2 * e2
            v = r1 * c1 * e1 + r2 * c2 * e2
        }
        return SpringState(position: target + x, velocity: v)
    }

    /// True when within `positionEpsilon` of target and slower than `velocityEpsilon`.
    public static func isSettled(_ state: SpringState, target: Double, positionEpsilon: Double = 0.5, velocityEpsilon: Double = 5) -> Bool {
        abs(state.position - target) < positionEpsilon && abs(state.velocity) < velocityEpsilon
    }
}

/// Animates a window origin (x and y independently) with a spring. Size is not animated:
/// the applier sets size once at the start (resizing every frame through AX makes apps
/// relayout constantly and stutter).
public struct OriginSpring: Equatable, Sendable {
    public var x: SpringState
    public var y: SpringState
    public var target: CGPoint

    public init(from origin: CGPoint, to target: CGPoint, velocity: CGVector = .zero) {
        self.x = SpringState(position: Double(origin.x), velocity: Double(velocity.dx))
        self.y = SpringState(position: Double(origin.y), velocity: Double(velocity.dy))
        self.target = target
    }

    public var origin: CGPoint { CGPoint(x: x.position, y: y.position) }

    /// Returns the spring advanced by `dt`.
    public func stepped(dt: Double, parameters: SpringParameters) -> OriginSpring {
        var next = self
        next.x = Spring.step(x, target: Double(target.x), parameters: parameters, dt: dt)
        next.y = Spring.step(y, target: Double(target.y), parameters: parameters, dt: dt)
        return next
    }

    /// Returns a spring retargeted to `newTarget`, keeping current position and velocity
    /// (so an animation interrupted by another key press continues smoothly).
    public func retargeted(to newTarget: CGPoint) -> OriginSpring {
        var next = self
        next.target = newTarget
        return next
    }

    public var isSettled: Bool {
        Spring.isSettled(x, target: Double(target.x)) && Spring.isSettled(y, target: Double(target.y))
    }
}

extension SpringParameters {
    /// Tolerant decoding: every missing or malformed field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpringParameters()
        self.init(stiffness: c.value(.stiffness, default: d.stiffness), dampingRatio: c.value(.dampingRatio, default: d.dampingRatio))
    }
}
