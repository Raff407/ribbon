import AppKit
import os
import RibbonCore

private let log = Logger(subsystem: "com.raff.ribbon", category: "Gestures")

/// `GestureSource` combining two inputs: horizontal scrolling while the configured
/// modifiers are held (CGEventTap — trackpads and mouse wheels) and, optionally, bare
/// multi-finger swipes (MultitouchSupport). Main thread only.
public final class TrackpadGestureMonitor: GestureSource {
    public var handler: ((GestureEvent) -> Void)?

    private var settings = TrackpadSettings()
    private let tap = ScrollTap()
    private let swipe = MultitouchSwipe()
    private var interpreter = ScrollGestureInterpreter()
    private var idleTimer: Timer?
    private var isStarted = false

    public init() {
        tap.sampleHandler = { [weak self] sample in self?.handleScroll(sample) ?? false }
        tap.interruptionHandler = { [weak self] in self?.cancelScrollGesture() }
        swipe.handler = { [weak self] event in self?.handler?(event) }
    }

    deinit {
        idleTimer?.invalidate()
    }

    public func configure(_ settings: TrackpadSettings) {
        self.settings = settings
        swipe.configure(fingers: settings.swipeFingers, sensitivity: settings.sensitivity, invert: settings.invertDirection)
        if isStarted { applyRunningState() }
    }

    public func start() {
        isStarted = true
        applyRunningState()
    }

    public func stop() {
        isStarted = false
        cancelScrollGesture()
        tap.stop()
        swipe.cancelGesture()
        swipe.stop()
    }

    /// Starts/stops each input to match the settings.
    private func applyRunningState() {
        if settings.scrollWithModifierEnabled {
            if !tap.start() { log.error("Scroll tap unavailable (Accessibility permission?) — will retry on next start") }
        } else {
            cancelScrollGesture()
            tap.stop()
        }
        if settings.swipeEnabled {
            if !swipe.start() { log.error("Multitouch swipe unavailable on this Mac") }
        } else {
            swipe.cancelGesture()
            swipe.stop()
        }
    }

    // MARK: Scroll

    /// Returns true to swallow the event.
    private func handleScroll(_ sample: ScrollSample) -> Bool {
        let (next, outcome) = interpreter.interpret(sample, config: ScrollConfig(settings))
        interpreter = next
        if outcome.armIdleTimer { armIdleTimer() } else if !interpreter.isActive { disarmIdleTimer() }
        outcome.events.forEach { handler?($0) }
        return outcome.swallow
    }

    private func armIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: ScrollGestureInterpreter.idleTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            let (next, events) = self.interpreter.idleTimedOut()
            self.interpreter = next
            self.idleTimer = nil
            events.forEach { self.handler?($0) }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func disarmIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func cancelScrollGesture() {
        disarmIdleTimer()
        let (next, events) = interpreter.cancelled()
        interpreter = next
        events.forEach { handler?($0) }
    }
}
