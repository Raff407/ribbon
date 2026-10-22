import AppKit
import RibbonCore

/// Leading-edge throttle with one trailing emission, so the last position of a fast
/// mouse movement is always delivered. Pure value type; the owner performs the effects.
struct ThrottleGate: Equatable {
    enum Decision: Equatable {
        case emitNow
        /// Emit once after this many seconds (nothing is scheduled yet).
        case scheduleTrailing(after: TimeInterval)
        /// A trailing emission is already scheduled; it will report the latest state.
        case drop
    }

    let interval: TimeInterval
    private(set) var lastEmit: TimeInterval?
    private(set) var trailingScheduled = false

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func decide(now: TimeInterval) -> Decision {
        guard let lastEmit, now - lastEmit < interval else { return .emitNow }
        return trailingScheduled ? .drop : .scheduleTrailing(after: interval - (now - lastEmit))
    }

    func emitted(at now: TimeInterval) -> ThrottleGate {
        var next = self
        next.lastEmit = now
        next.trailingScheduled = false
        return next
    }

    func schedulingTrailing() -> ThrottleGate {
        var next = self
        next.trailingScheduled = true
        return next
    }
}

/// `InputStateProviding` over `NSEvent` / CoreGraphics. All points are AX space.
public final class SystemInputState: InputStateProviding {
    public var mouseMovedHandler: ((CGPoint) -> Void)?
    public var mouseUpHandler: (() -> Void)?

    /// ~30 Hz, as the protocol promises.
    static let movedInterval: TimeInterval = 1.0 / 30.0
    private static let trackedEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var gate = ThrottleGate(interval: SystemInputState.movedInterval)
    private var trailingWork: DispatchWorkItem?

    public init() {}

    deinit {
        removeMonitors()
    }

    public func mouseLocation() -> CGPoint {
        CoordinateSpace.flip(NSEvent.mouseLocation, primaryHeight: PrimaryScreen.height)
    }

    public var isLeftMouseDown: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
    }

    /// CoreGraphics global display coordinates share AX space's origin and orientation,
    /// so the point is used as is.
    public func warpMouse(to point: CGPoint) {
        let error = CGWarpMouseCursorPosition(point)
        if error != .success {
            AXLog.input.error("CGWarpMouseCursorPosition failed: \(error.rawValue)")
        }
        // Re-associate immediately; warping otherwise freezes the cursor for ~0.25 s.
        _ = CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func setMouseTracking(_ enabled: Bool) {
        if enabled {
            installMonitors()
        } else {
            removeMonitors()
        }
    }

    // MARK: Monitors

    private func installMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.trackedEvents) { [weak self] event in
            self?.handle(event.type)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.trackedEvents) { [weak self] event in
            self?.handle(event.type)
            return event
        }
        if globalMonitor == nil {
            AXLog.input.error("Global mouse monitor could not be installed")
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        trailingWork?.cancel()
        trailingWork = nil
        gate = ThrottleGate(interval: Self.movedInterval)
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseUp:
            mouseUpHandler?()
        case .mouseMoved, .leftMouseDragged:
            mouseMoved()
        default:
            break
        }
    }

    private func mouseMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        switch gate.decide(now: now) {
        case .emitNow:
            trailingWork?.cancel()
            trailingWork = nil
            emitMoved(at: now)
        case .scheduleTrailing(let delay):
            gate = gate.schedulingTrailing()
            let work = DispatchWorkItem { [weak self] in
                self?.trailingWork = nil
                self?.emitMoved(at: ProcessInfo.processInfo.systemUptime)
            }
            trailingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .drop:
            break
        }
    }

    private func emitMoved(at now: TimeInterval) {
        gate = gate.emitted(at: now)
        mouseMovedHandler?(mouseLocation())
    }
}
