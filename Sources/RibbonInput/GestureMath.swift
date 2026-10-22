import Foundation
import RibbonCore

// The decision logic behind TrackpadGestureMonitor, as pure value types: raw scroll
// events / finger frames in, GestureEvents out. No OS calls, no clocks — every input
// carries its own timestamp — so the behaviour is deterministic and testable.

// MARK: - Velocity

/// Viewport velocity (points/second) from recent movement samples.
struct VelocityTracker: Equatable {
    struct Sample: Equatable {
        let time: TimeInterval
        let dx: Double
    }

    /// Velocity is measured over the movement in the last `window` seconds.
    static let window: TimeInterval = 0.08
    static let maxSamples = 32
    /// Clamp so a burst of events with tiny dt can't fling the strip into orbit.
    static let maxSpeed: Double = 20_000
    private static let minSpan: TimeInterval = 1.0 / 500

    private(set) var samples: [Sample] = []

    func adding(dx: Double, at time: TimeInterval) -> VelocityTracker {
        let horizon = time - Self.window * 2
        let kept = (samples + [Sample(time: time, dx: dx)]).filter { $0.time >= horizon }
        var next = self
        next.samples = Array(kept.suffix(Self.maxSamples))
        return next
    }

    /// Velocity over the `window` seconds ending at `time`. Movement that stopped before
    /// the window (fingers held still, then lifted) gives 0.
    func velocity(at time: TimeInterval) -> Double {
        let recent = samples.filter { $0.time >= time - Self.window && $0.time <= time }
        guard let first = recent.first, let last = recent.last else { return 0 }
        let span = last.time - first.time
        let raw: Double
        if recent.count >= 2, span >= Self.minSpan {
            // The first sample's movement happened before its timestamp: it's the anchor.
            raw = recent.dropFirst().reduce(0) { $0 + $1.dx } / span
        } else {
            raw = recent.reduce(0) { $0 + $1.dx } / Self.window
        }
        return min(max(raw, -Self.maxSpeed), Self.maxSpeed)
    }
}

// MARK: - Modifier scroll

/// `scrollWheelEventScrollPhase` values.
enum ScrollPhase: Equatable {
    case none, began, changed, ended, cancelled, mayBegin, unknown

    init(raw: Int64) {
        switch raw {
        case 0: self = .none
        case 1: self = .began
        case 2: self = .changed
        case 4: self = .ended
        case 8: self = .cancelled
        case 128: self = .mayBegin
        default: self = .unknown
        }
    }
}

/// One scroll-wheel event, reduced to what the interpreter needs.
struct ScrollSample: Equatable {
    var phase: ScrollPhase
    /// `scrollWheelEventMomentumPhase`: 0 none, 1 begin, 2 continue, 3 end.
    var momentumPhase: Int64
    /// Horizontal point delta (`scrollWheelEventPointDeltaAxis2`).
    var deltaX: Double
    /// Vertical point delta (`scrollWheelEventPointDeltaAxis1`).
    var deltaY: Double
    var modifiers: ModifierSet
    /// Seconds, any monotonic clock (only differences matter).
    var time: TimeInterval

    static let momentumEnd: Int64 = 3

    /// Horizontal if |h| ≥ |v|, else vertical, so a plain mouse wheel scrolls the strip.
    var dominantDelta: Double { abs(deltaX) >= abs(deltaY) ? deltaX : deltaY }
    var isMomentum: Bool { momentumPhase != 0 }
}

struct ScrollConfig: Equatable {
    var modifiers: ModifierSet
    var sensitivity: Double
    var invert: Bool

    init(modifiers: ModifierSet, sensitivity: Double, invert: Bool) {
        self.modifiers = modifiers
        self.sensitivity = sensitivity
        self.invert = invert
    }

    init(_ settings: TrackpadSettings) {
        self.init(modifiers: settings.scrollModifiers, sensitivity: settings.sensitivity,
                  invert: settings.invertDirection)
    }

    /// The strip only takes over scrolling while *all* the configured modifiers are held.
    /// An empty modifier set never engages (it would hijack every scroll on the system).
    func engages(_ held: ModifierSet) -> Bool {
        !modifiers.isEmpty && held.isSuperset(of: modifiers)
    }

    /// Viewport dx for a raw scroll delta: `-delta * sensitivity`, negated again if inverted.
    func viewportDelta(_ delta: Double) -> Double {
        let dx = -delta * sensitivity
        return invert ? -dx : dx
    }
}

/// What to do with one scroll event.
struct ScrollOutcome: Equatable {
    /// Drop the event so the app under the cursor doesn't also scroll.
    var swallow: Bool
    var events: [GestureEvent]
    /// A phase-less (mouse wheel) gesture is in progress: (re)arm the idle timer that
    /// calls `idleTimedOut()` after `ScrollGestureInterpreter.idleTimeout`.
    var armIdleTimer: Bool

    static let passThrough = ScrollOutcome(swallow: false, events: [], armIdleTimer: false)
}

/// Maps scroll events to strip gestures.
///
/// * Trackpad (phased) events: may-begin/began → `.began`, changed → `.changed`,
///   ended → `.ended(velocity)`, cancelled → `.cancelled`.
/// * Momentum events are swallowed and ignored — while the modifiers are held, and for
///   the tail of a gesture Ribbon consumed (so the app doesn't get an orphan fling).
/// * Phase-less (mouse wheel) events: `.began` on the first, `.changed` per event,
///   `.ended` when the idle timer fires.
/// * Releasing the modifiers mid-gesture ends the gesture; later events pass through.
struct ScrollGestureInterpreter: Equatable {
    enum State: Equatable {
        case idle, phased, phaseless
    }

    static let idleTimeout: TimeInterval = 0.15

    private(set) var state: State = .idle
    private(set) var swallowingMomentum = false
    private(set) var velocity = VelocityTracker()
    private(set) var lastEventTime: TimeInterval = 0

    var isActive: Bool { state != .idle }

    func interpret(_ sample: ScrollSample, config: ScrollConfig) -> (ScrollGestureInterpreter, ScrollOutcome) {
        if sample.isMomentum { return momentum(sample, config: config) }
        var base = self
        base.swallowingMomentum = false
        guard config.engages(sample.modifiers) else { return base.disengaged(at: sample.time) }
        switch sample.phase {
        case .none: return base.phaseless(sample, config: config)
        case .mayBegin, .began: return base.moved(sample, config: config, into: .phased)
        case .changed, .unknown: return base.moved(sample, config: config, into: .phased)
        case .ended: return base.ended(sample, config: config)
        case .cancelled: return base.cancelledByOS()
        }
    }

    /// The phase-less idle timer fired: end the mouse-wheel gesture.
    func idleTimedOut() -> (ScrollGestureInterpreter, [GestureEvent]) {
        guard state == .phaseless else { return (self, []) }
        return (ScrollGestureInterpreter(), [.ended(velocity: velocity.velocity(at: lastEventTime))])
    }

    /// Abandons any gesture (tap disabled, scrolling turned off): `.cancelled` if active.
    func cancelled() -> (ScrollGestureInterpreter, [GestureEvent]) {
        (ScrollGestureInterpreter(), isActive ? [.cancelled] : [])
    }

    // MARK: Cases

    private func momentum(_ sample: ScrollSample, config: ScrollConfig) -> (ScrollGestureInterpreter, ScrollOutcome) {
        let swallow = swallowingMomentum || config.engages(sample.modifiers)
        var next = self
        if sample.momentumPhase == ScrollSample.momentumEnd { next.swallowingMomentum = false }
        return (next, ScrollOutcome(swallow: swallow, events: [], armIdleTimer: false))
    }

    /// Modifiers not held: finish an active gesture where it is and let the event through.
    private func disengaged(at time: TimeInterval) -> (ScrollGestureInterpreter, ScrollOutcome) {
        guard isActive else { return (self, .passThrough) }
        let end = state == .phaseless ? lastEventTime : time
        let events: [GestureEvent] = [.ended(velocity: velocity.velocity(at: end))]
        return (ScrollGestureInterpreter(), ScrollOutcome(swallow: false, events: events, armIdleTimer: false))
    }

    /// began / may-begin / changed: start the gesture if needed, then report movement.
    private func moved(
        _ sample: ScrollSample, config: ScrollConfig, into newState: State
    ) -> (ScrollGestureInterpreter, ScrollOutcome) {
        let (started, startEvents) = startingIfIdle(newState)
        var next = started
        next.state = newState
        let (moved, moveEvents) = next.recording(sample, config: config)
        return (moved, ScrollOutcome(swallow: true, events: startEvents + moveEvents, armIdleTimer: false))
    }

    private func phaseless(_ sample: ScrollSample, config: ScrollConfig) -> (ScrollGestureInterpreter, ScrollOutcome) {
        // A wheel event during a trackpad gesture is just more movement.
        let target: State = state == .phased ? .phased : .phaseless
        let (started, startEvents) = startingIfIdle(target)
        var next = started
        next.state = target
        let (moved, moveEvents) = next.recording(sample, config: config)
        let outcome = ScrollOutcome(swallow: true, events: startEvents + moveEvents,
                                    armIdleTimer: target == .phaseless)
        return (moved, outcome)
    }

    private func ended(_ sample: ScrollSample, config: ScrollConfig) -> (ScrollGestureInterpreter, ScrollOutcome) {
        // An end without a start we saw belongs to the app.
        guard isActive else { return (self, .passThrough) }
        let (moved, moveEvents) = recording(sample, config: config)
        let velocity = moved.velocity.velocity(at: sample.time)
        var next = ScrollGestureInterpreter()
        next.swallowingMomentum = true
        let events = moveEvents + [.ended(velocity: velocity)]
        return (next, ScrollOutcome(swallow: true, events: events, armIdleTimer: false))
    }

    private func cancelledByOS() -> (ScrollGestureInterpreter, ScrollOutcome) {
        guard isActive else { return (self, .passThrough) }
        return (ScrollGestureInterpreter(), ScrollOutcome(swallow: true, events: [.cancelled], armIdleTimer: false))
    }

    // MARK: Helpers

    private func startingIfIdle(_ newState: State) -> (ScrollGestureInterpreter, [GestureEvent]) {
        guard state == .idle else { return (self, []) }
        var next = self
        next.state = newState
        next.velocity = VelocityTracker()
        return (next, [.began])
    }

    private func recording(_ sample: ScrollSample, config: ScrollConfig) -> (ScrollGestureInterpreter, [GestureEvent]) {
        var next = self
        next.lastEventTime = sample.time
        let dx = config.viewportDelta(sample.dominantDelta)
        guard dx != 0 else { return (next, []) }
        next.velocity = velocity.adding(dx: dx, at: sample.time)
        return (next, [.changed(dx: dx)])
    }
}

// MARK: - Multi-finger swipe

/// One multitouch frame, reduced to what the swipe tracker needs.
struct TouchFrame: Equatable {
    /// Identifies the trackpad (frames from a second trackpad are ignored mid-gesture).
    var device: Int
    /// Fingers touching the surface.
    var fingerCount: Int
    /// Mean normalized position of those fingers, 0...1 (x: left → right).
    var meanX: Double
    var meanY: Double
    /// Seconds (the frame's own timestamp).
    var time: TimeInterval
}

struct SwipeConfig: Equatable {
    var fingers: Int
    var sensitivity: Double
    var invert: Bool
    /// Width of the screen the gesture maps onto, in points.
    var screenWidth: Double

    /// Viewport dx for a normalized finger movement: `-Δx * screenWidth * sensitivity`.
    func viewportDelta(_ normalizedDX: Double) -> Double {
        let dx = -normalizedDX * screenWidth * sensitivity
        return invert ? -dx : dx
    }
}

/// Follows finger frames: a gesture starts when exactly `fingers` touches are down and
/// their mean movement is mostly horizontal; it ends when the finger count changes.
struct SwipeTracker: Equatable {
    enum State: Equatable {
        case idle
        /// The right number of fingers is down; waiting to see which axis dominates.
        case candidate(device: Int, startX: Double, startY: Double)
        case tracking(device: Int, lastX: Double)
        /// Vertical movement: not ours. Ignored until the finger count changes.
        case rejected(device: Int)

        var device: Int? {
            switch self {
            case .idle: return nil
            case .candidate(let device, _, _), .tracking(let device, _), .rejected(let device): return device
            }
        }
    }

    /// Normalized distance the fingers must travel before the axis is decided.
    static let decisionDistance = 0.015

    private(set) var state: State = .idle
    private(set) var velocity = VelocityTracker()

    var isTracking: Bool {
        if case .tracking = state { return true }
        return false
    }

    func process(_ frame: TouchFrame, config: SwipeConfig) -> (SwipeTracker, [GestureEvent]) {
        if let device = state.device, device != frame.device { return (self, []) }
        guard frame.fingerCount == config.fingers else { return ended(at: frame.time) }
        switch state {
        case .idle:
            var next = self
            next.state = .candidate(device: frame.device, startX: frame.meanX, startY: frame.meanY)
            return (next, [])
        case .candidate(let device, let startX, let startY):
            return decide(frame, device: device, startX: startX, startY: startY, config: config)
        case .tracking(let device, let lastX):
            let dx = config.viewportDelta(frame.meanX - lastX)
            var next = self
            next.state = .tracking(device: device, lastX: frame.meanX)
            next.velocity = velocity.adding(dx: dx, at: frame.time)
            return (next, dx == 0 ? [] : [.changed(dx: dx)])
        case .rejected:
            return (self, [])
        }
    }

    /// Ends a tracked gesture (finger count changed, swipe turned off).
    func ended(at time: TimeInterval) -> (SwipeTracker, [GestureEvent]) {
        guard isTracking else { return (SwipeTracker(), []) }
        return (SwipeTracker(), [.ended(velocity: velocity.velocity(at: time))])
    }

    /// Abandons any gesture: `.cancelled` if one was being tracked.
    func cancelled() -> (SwipeTracker, [GestureEvent]) {
        (SwipeTracker(), isTracking ? [.cancelled] : [])
    }

    private func decide(
        _ frame: TouchFrame, device: Int, startX: Double, startY: Double, config: SwipeConfig
    ) -> (SwipeTracker, [GestureEvent]) {
        let moveX = frame.meanX - startX
        let moveY = frame.meanY - startY
        guard max(abs(moveX), abs(moveY)) >= Self.decisionDistance else { return (self, []) }
        var next = self
        guard abs(moveX) > abs(moveY) else {
            next.state = .rejected(device: device)
            return (next, [])
        }
        // Report the movement that happened while deciding, so nothing is lost.
        let dx = config.viewportDelta(moveX)
        next.state = .tracking(device: device, lastX: frame.meanX)
        next.velocity = VelocityTracker().adding(dx: dx, at: frame.time)
        return (next, [.began, .changed(dx: dx)])
    }
}
