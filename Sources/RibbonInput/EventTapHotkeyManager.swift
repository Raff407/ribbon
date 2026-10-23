import AppKit
import CoreGraphics
import os
import RibbonCore

private let log = Logger(subsystem: "com.raff.ribbon", category: "Hotkeys")

/// Global shortcuts through an active keyboard event tap running on its own thread.
///
/// Unlike Carbon hotkeys this handles ⌥-only combinations (which recent macOS restricts
/// for `RegisterEventHotKey`) and needs only the Accessibility permission Ribbon already
/// has. The tap thread just looks the key up in a table and hops to the main thread to
/// run the command, so typing never waits on Ribbon's main thread. Held keys repeat at the
/// system key-repeat rate for navigation/resize commands. If the tap can't be created
/// (no permission yet) it falls back to `CarbonHotkeyManager`.
public final class EventTapHotkeyManager: HotkeyRegistering {
    public var commandHandler: ((Command) -> Void)? {
        didSet {
            state.onCommand = commandHandler
            fallback.commandHandler = commandHandler
        }
    }

    public var modifierHoldHandler: ((Bool) -> Void)? {
        didSet {
            state.onHold = modifierHoldHandler
            fallback.modifierHoldHandler = usingFallback ? modifierHoldHandler : nil
        }
    }

    private let state = HotkeyTapState()
    private let fallback = CarbonHotkeyManager()
    private var usingFallback = false
    private var port: CFMachPort?

    public init() {}

    deinit {
        stopTap()
    }

    @discardableResult
    public func register(_ bindings: [KeyBinding]) -> [KeyBinding] {
        var table: [KeyCombo: Command] = [:]
        var failed: [KeyBinding] = []
        for entry in HotkeyPlan.make(bindings) {
            switch entry {
            case .register(let binding): table[binding.combo] = binding.command
            case .conflict(let binding), .rejected(let binding): failed.append(binding)
            case .duplicate: break
            }
        }
        let acceptedBindings = table.map { KeyBinding(command: $0.value, combo: $0.key) }
        state.update(table: table, holdModifiers: Self.primaryModifiers(of: acceptedBindings))
        guard startTapIfNeeded() else {
            log.error("Keyboard event tap unavailable; using Carbon hotkeys")
            usingFallback = true
            fallback.modifierHoldHandler = modifierHoldHandler
            return fallback.register(bindings)
        }
        if usingFallback {
            fallback.unregisterAll()
            fallback.modifierHoldHandler = nil
            usingFallback = false
        }
        log.debug("Registered \(table.count) shortcuts on the event tap")
        return failed
    }

    public func unregisterAll() {
        state.update(table: [:], holdModifiers: [])
        fallback.unregisterAll()
        fallback.modifierHoldHandler = nil
        usingFallback = false
    }

    public func setSuspended(_ suspended: Bool) {
        state.setSuspended(suspended)
        fallback.setSuspended(suspended)
    }

    /// The modifier set most shortcuts share (ignoring ⇧) — holding it keeps the strip
    /// indicator up.
    static func primaryModifiers(of bindings: [KeyBinding]) -> ModifierSet {
        let counts = Dictionary(bindings.map { ($0.combo.modifiers.subtracting(.shift), 1) }, uniquingKeysWith: +)
        return counts.filter { !$0.key.isEmpty }.max {
            $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value
        }?.key ?? []
    }

    // MARK: Tap lifecycle

    private func startTapIfNeeded() -> Bool {
        if port != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let retained = Unmanaged.passRetained(state)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: retained.toOpaque()
        ) else {
            retained.release()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            retained.release()
            return false
        }
        self.port = port
        state.install(port)
        let state = self.state
        let thread = Thread {
            // The callback context stays alive until this thread has finished servicing
            // the source, including any callback already in progress during shutdown.
            defer { retained.release() }
            guard let runLoop = CFRunLoopGetCurrent() else { return }
            guard state.start(on: runLoop, source: source) else { return }
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            state.finished()
        }
        thread.name = "com.raff.ribbon.hotkeys"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.start()
        return true
    }

    private func stopTap() {
        state.stop()
        self.port = nil
    }
}

/// Everything the tap thread touches, behind one lock.
final class HotkeyTapState {
    private let lock = NSLock()
    private var table: [KeyCombo: Command] = [:]
    private var holdModifiers: ModifierSet = []
    private var suspended = false
    private var holding = false
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?
    private var stopped = false
    private var generation: UInt64 = 0
    /// Main-thread state can lag behind the tap's `holding` while a release is queued.
    private var deliveredHolding = false
    /// Called on the main thread.
    var onCommand: ((Command) -> Void)?
    var onHold: ((Bool) -> Void)?

    func update(table: [KeyCombo: Command], holdModifiers: ModifierSet) {
        lock.lock()
        guard self.table != table || self.holdModifiers != holdModifiers else { lock.unlock(); return }
        generation &+= 1
        let wasHolding = holding
        holding = false
        self.table = table
        self.holdModifiers = holdModifiers
        lock.unlock()
        releaseHold(wasHolding: wasHolding)
    }

    func setSuspended(_ value: Bool) {
        lock.lock()
        guard suspended != value else { lock.unlock(); return }
        generation &+= 1
        suspended = value
        let wasHolding = holding
        holding = false
        lock.unlock()
        releaseHold(wasHolding: wasHolding)
    }

    private func releaseHold(wasHolding: Bool) {
        guard wasHolding || deliveredHolding else { return }
        deliveredHolding = false
        onHold?(false)
    }

    func install(_ port: CFMachPort) {
        lock.lock()
        self.port = port
        lock.unlock()
    }

    /// Serializes startup with shutdown: deinit may happen before the thread starts.
    func start(on runLoop: CFRunLoop, source: CFRunLoopSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let port else { return false }
        self.runLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        lock.lock()
        stopped = true
        generation &+= 1
        let port = self.port
        let runLoop = self.runLoop
        self.port = nil
        lock.unlock()
        if let runLoop {
            // A queued stop also works when shutdown wins the race with CFRunLoopRun.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(runLoop) }
            CFRunLoopWakeUp(runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
    }

    func finished() {
        lock.lock()
        runLoop = nil
        lock.unlock()
    }

    /// The command for a key press, or nil to let the event through. `swallowOnly` means
    /// "eat it but do nothing" (OS auto-repeat of a command that shouldn't repeat).
    func command(forKeyCode keyCode: UInt32, modifiers: ModifierSet, isRepeat: Bool) -> (command: Command, swallowOnly: Bool, generation: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !suspended, let command = table[KeyCombo(keyCode: keyCode, modifiers: modifiers)] else { return nil }
        return (command, isRepeat && !RepeatPolicy.isRepeatable(command), generation)
    }

    /// Hold transitions of the primary modifier set (nil when unchanged).
    func holdTransition(for modifiers: ModifierSet) -> (held: Bool, generation: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        let held = !stopped && !suspended && !holdModifiers.isEmpty && modifiers.isSuperset(of: holdModifiers)
        guard held != holding else { return nil }
        holding = held
        return (held, generation)
    }

    func reenable() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let port else { return }
        log.info("Hotkey tap was disabled by macOS; re-enabling")
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && !suspended && generation == token
    }

    func dispatch(_ command: Command, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.onCommand?(command)
        }
    }

    func dispatchHold(_ held: Bool, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.deliveredHolding = held
            self.onHold?(held)
        }
    }
}

/// Runs on the hotkey thread. Must not capture context: `refcon` is the retained state.
private func hotkeyTapCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let passThrough = Unmanaged.passUnretained(event)
    guard let refcon else { return passThrough }
    let state = Unmanaged<HotkeyTapState>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        state.reenable()
        return passThrough
    case .flagsChanged:
        if let transition = state.holdTransition(for: ModifierConversion.modifiers(from: event.flags)) {
            state.dispatchHold(transition.held, generation: transition.generation)
        }
        return passThrough
    case .keyDown:
        let keyCode = UInt32(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = ModifierConversion.modifiers(from: event.flags)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard let match = state.command(forKeyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat) else {
            return passThrough
        }
        if !match.swallowOnly { state.dispatch(match.command, generation: match.generation) }
        return nil
    default:
        return passThrough
    }
}
