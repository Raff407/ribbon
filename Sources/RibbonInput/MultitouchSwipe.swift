import AppKit
import os
import RibbonCore

private let log = Logger(subsystem: "com.raff.ribbon", category: "Multitouch")

// Bare multi-finger trackpad swipes through the private MultitouchSupport framework,
// loaded with dlopen/dlsym so a missing framework or symbol just disables the feature.

// MARK: - Framework ABI

/// The widely used reverse-engineered finger record layout (96 bytes).
struct MTPoint {
    var x: Float
    var y: Float
}

struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    /// 1 start-in-range … 3 make-touch, 4 touching, 5 break-touch … 7 out-of-range.
    var state: Int32
    var foo3: Int32
    var foo4: Int32
    /// Normalized 0...1, origin bottom-left of the trackpad.
    var normalized: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var millimeters: MTVector
    var zero2: (Int32, Int32)
    var unk2: Float

    static let expectedSize = 96
    /// States that mean "finger on the surface".
    static let touchingStates: ClosedRange<Int32> = 3...4
}

/// `int callback(MTDeviceRef, Finger *touches, int count, double timestamp, int frame)`.
typealias MTContactCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

/// The few MultitouchSupport functions Ribbon needs, resolved once.
struct MultitouchAPI {
    typealias CreateList = @convention(c) () -> UnsafeMutableRawPointer?
    typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
    typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Void

    static let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    let createList: CreateList
    let register: RegisterCallback
    let unregister: RegisterCallback
    let start: DeviceStart
    let stop: DeviceStop

    /// nil when the framework or a symbol is missing, or the record layout is off.
    static let shared: MultitouchAPI? = load()

    private static func load() -> MultitouchAPI? {
        guard MemoryLayout<MTTouch>.size == MTTouch.expectedSize else {
            log.error("Unexpected MTTouch size \(MemoryLayout<MTTouch>.size); swipes disabled")
            return nil
        }
        // Never dlclose'd: the callbacks live as long as the process.
        guard let handle = dlopen(path, RTLD_LAZY) else {
            log.error("dlopen MultitouchSupport failed: \(String(cString: dlerror()), privacy: .public)")
            return nil
        }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else {
                log.error("MultitouchSupport is missing \(name, privacy: .public)")
                return nil
            }
            return unsafeBitCast(raw, to: T.self)
        }
        guard let createList = symbol("MTDeviceCreateList", CreateList.self),
              let register = symbol("MTRegisterContactFrameCallback", RegisterCallback.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", RegisterCallback.self),
              let start = symbol("MTDeviceStart", DeviceStart.self),
              let stop = symbol("MTDeviceStop", DeviceStop.self)
        else { return nil }
        return MultitouchAPI(createList: createList, register: register, unregister: unregister,
                             start: start, stop: stop)
    }
}

// MARK: - Callback routing

/// The C callback has no context pointer, so frames go through this static router: it
/// filters on the callback thread (cheap, lock-protected) and hops to the main thread,
/// where the current receiver handles them.
enum MultitouchRouter {
    private static let lock = NSLock()
    private static var accepting = false
    private static var fingers = 3
    private static var lastCounts: [Int: Int] = [:]
    private static var generation: UInt64 = 0

    /// Main thread only.
    static weak var receiver: MultitouchSwipe?

    static func setAccepting(_ accept: Bool, fingers count: Int) {
        lock.lock()
        accepting = accept
        fingers = count
        lastCounts = [:]
        generation &+= 1
        lock.unlock()
    }

    /// Callback thread. Forwards frames with the swipe finger count, plus any frame where
    /// the count changed (that's what ends a gesture); drops the rest (cursor movement).
    static func deliver(_ frame: TouchFrame) {
        lock.lock()
        let relevant = accepting
            && (frame.fingerCount == fingers || frame.fingerCount != lastCounts[frame.device, default: 0])
        if accepting { lastCounts[frame.device] = frame.fingerCount }
        let token = generation
        lock.unlock()
        guard relevant else { return }
        DispatchQueue.main.async {
            // Frames queued before a stop/restart or finger-count change belong to the
            // previous session; they must not start a gesture in the new one.
            lock.lock()
            let current = accepting && generation == token
            lock.unlock()
            guard current else { return }
            receiver?.handle(frame)
        }
    }

    /// Reduces the raw finger records (valid only during the callback) to a TouchFrame.
    static func summarize(
        device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, count: Int, timestamp: Double
    ) -> TouchFrame {
        let id = Int(bitPattern: device)
        guard let touches, count > 0, count <= 32 else {
            return TouchFrame(device: id, fingerCount: 0, meanX: 0, meanY: 0, time: timestamp)
        }
        let stride = MemoryLayout<MTTouch>.stride
        var downCount = 0
        var sumX = 0.0
        var sumY = 0.0
        // This runs for every raw frame, including ordinary pointer movement. Reduce
        // directly instead of allocating and traversing two arrays on the callback thread.
        for index in 0..<count {
            let touch = touches.load(fromByteOffset: index * stride, as: MTTouch.self)
            guard MTTouch.touchingStates.contains(touch.state) else { continue }
            downCount += 1
            sumX += Double(touch.normalized.position.x)
            sumY += Double(touch.normalized.position.y)
        }
        guard downCount > 0 else {
            return TouchFrame(device: id, fingerCount: 0, meanX: 0, meanY: 0, time: timestamp)
        }
        let n = Double(downCount)
        return TouchFrame(device: id, fingerCount: downCount, meanX: sumX / n, meanY: sumY / n, time: timestamp)
    }
}

/// MultitouchSupport contact-frame callback (runs on a framework thread).
private func multitouchFrameCallback(
    _ device: UnsafeMutableRawPointer?, _ touches: UnsafeMutableRawPointer?,
    _ count: Int32, _ timestamp: Double, _ frame: Int32
) -> Int32 {
    let summary = MultitouchRouter.summarize(device: device, touches: touches, count: Int(count), timestamp: timestamp)
    MultitouchRouter.deliver(summary)
    return 0
}

// MARK: - Swipe source

/// Turns multi-finger horizontal swipes into GestureEvents. Main thread only.
final class MultitouchSwipe {
    var handler: ((GestureEvent) -> Void)?

    private(set) var isRunning = false
    private var fingers = 3
    private var sensitivity = 1.0
    private var invert = false

    /// Keeps the device refs alive while they're started.
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var tracker = SwipeTracker()
    private var screenWidth: Double = 1440
    private var wakeObserver: NSObjectProtocol?

    /// Delay before restarting devices after wake (they stop delivering frames on sleep).
    private static let wakeRestartDelay: TimeInterval = 1.0

    deinit {
        stopDevices()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func configure(fingers: Int, sensitivity: Double, invert: Bool) {
        let clamped = min(max(fingers, 2), 5)
        if clamped != self.fingers { cancelGesture() }
        self.fingers = clamped
        self.sensitivity = sensitivity
        self.invert = invert
        if isRunning { MultitouchRouter.setAccepting(true, fingers: clamped) }
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard startDevices() else { return false }
        observeWake()
        return true
    }

    /// Stops listening. Any gesture in progress is dropped silently.
    func stop() {
        stopDevices()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Ends a gesture in progress with `.cancelled` (no-op when idle).
    func cancelGesture() {
        let (next, events) = tracker.cancelled()
        tracker = next
        events.forEach { handler?($0) }
    }

    fileprivate func handle(_ frame: TouchFrame) {
        guard isRunning else { return }
        if case .idle = tracker.state { screenWidth = Self.currentScreenWidth() }
        let config = SwipeConfig(fingers: fingers, sensitivity: sensitivity, invert: invert, screenWidth: screenWidth)
        let (next, events) = tracker.process(frame, config: config)
        tracker = next
        events.forEach { handler?($0) }
    }

    // MARK: Devices

    private func startDevices() -> Bool {
        guard let api = MultitouchAPI.shared else { return false }
        guard let raw = api.createList() else {
            log.error("MTDeviceCreateList returned nil")
            return false
        }
        let list = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        let found = (0..<CFArrayGetCount(list)).compactMap { index -> UnsafeMutableRawPointer? in
            CFArrayGetValueAtIndex(list, index).map { UnsafeMutableRawPointer(mutating: $0) }
        }
        guard !found.isEmpty else {
            log.info("No multitouch devices found")
            return false
        }
        MultitouchRouter.receiver = self
        MultitouchRouter.setAccepting(true, fingers: fingers)
        for device in found {
            api.register(device, multitouchFrameCallback)
            api.start(device, 0)
        }
        deviceList = list
        devices = found
        tracker = SwipeTracker()
        isRunning = true
        log.debug("Listening to \(found.count) multitouch device(s)")
        return true
    }

    private func stopDevices() {
        guard isRunning else { return }
        MultitouchRouter.setAccepting(false, fingers: fingers)
        if let api = MultitouchAPI.shared {
            for device in devices {
                api.unregister(device, multitouchFrameCallback)
                api.stop(device)
            }
        }
        if MultitouchRouter.receiver === self { MultitouchRouter.receiver = nil }
        devices = []
        deviceList = nil
        tracker = SwipeTracker()
        isRunning = false
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeRestartDelay) { [weak self] in
                self?.restartAfterWake()
            }
        }
    }

    private func restartAfterWake() {
        guard isRunning else { return }
        log.debug("Restarting multitouch devices after wake")
        cancelGesture()
        stopDevices()
        _ = startDevices()
    }

    /// Width of the screen under the mouse (the strip a gesture scrolls lives there).
    private static func currentScreenWidth() -> Double {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        return Double(screen?.frame.width ?? 1440)
    }
}
