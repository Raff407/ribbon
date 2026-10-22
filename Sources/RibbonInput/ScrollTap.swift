import AppKit
import CoreGraphics
import os
import RibbonCore

private let log = Logger(subsystem: "com.raff.ribbon", category: "ScrollTap")

/// An active (event-swallowing) session event tap for scroll-wheel events, serviced on
/// the main run loop so the handler runs on the main thread.
///
/// The tap is re-enabled whenever macOS disables it (callback too slow / secure input).
/// Creating it needs the Accessibility permission; without it `start()` fails, logs and
/// can simply be called again later.
final class ScrollTap {
    /// Decides per event; return true to swallow it. Main thread.
    var sampleHandler: ((ScrollSample) -> Bool)?
    /// macOS disabled the tap and it was re-enabled: events were missed meanwhile.
    var interruptionHandler: (() -> Void)?

    /// Used when a wheel reports line deltas only (no point deltas).
    private static let pointsPerLine: Double = 10

    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { port != nil }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        // Unretained: stop() (also run by deinit) invalidates the port before we go away.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: scrollTapCallback, userInfo: refcon
        ) else {
            log.error("Could not create the scroll event tap (Accessibility not granted?); will retry on next start")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            log.error("Could not create a run-loop source for the scroll tap")
            CFMachPortInvalidate(port)
            return false
        }
        // Common modes: keep servicing the tap during menu tracking and modal loops,
        // otherwise every scroll on the system stalls until macOS times the tap out.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        log.debug("Scroll tap started")
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        source = nil
        port = nil
    }

    /// Called by the C callback.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reenable(after: type)
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            guard isRunning, Thread.isMainThread else { return Unmanaged.passUnretained(event) }
            let swallow = sampleHandler?(Self.sample(from: event)) ?? false
            return swallow ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func reenable(after type: CGEventType) {
        guard let port else { return }
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        log.info("Scroll tap disabled by \(reason, privacy: .public); re-enabling")
        CGEvent.tapEnable(tap: port, enable: true)
        if Thread.isMainThread {
            interruptionHandler?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.interruptionHandler?() }
        }
    }

    // MARK: Event decoding

    static func sample(from event: CGEvent) -> ScrollSample {
        var deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        var deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        if deltaX == 0, deltaY == 0 {
            deltaX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * pointsPerLine
            deltaY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * pointsPerLine
        }
        return ScrollSample(
            phase: ScrollPhase(raw: event.getIntegerValueField(.scrollWheelEventScrollPhase)),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            deltaX: deltaX,
            deltaY: deltaY,
            modifiers: ModifierConversion.modifiers(from: event.flags),
            time: timestamp(of: event)
        )
    }

    /// Seconds since boot. `CGEvent.timestamp`'s unit differs between Intel and Apple
    /// silicon, so let AppKit convert it; fall back to "now" (the tap runs promptly).
    private static func timestamp(of event: CGEvent) -> TimeInterval {
        NSEvent(cgEvent: event)?.timestamp ?? ProcessInfo.processInfo.systemUptime
    }
}

/// CGEventTap callback. `refcon` is the unretained `ScrollTap` that created the tap.
private func scrollTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
