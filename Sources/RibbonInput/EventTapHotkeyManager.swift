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
            fallback.modifierHoldHandler = modifierHoldHandler
        }
    }

    private let state = HotkeyTapState()
    private let fallback = CarbonHotkeyManager()
    private var usingFallback = false
    private var port: CFMachPort?
    private var retainedState: Unmanaged<HotkeyTapState>?

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
        state.update(table: table, holdModifiers: Self.primaryModifiers(of: bindings))
        guard startTapIfNeeded() else {
            log.error("Keyboard event tap unavailable; using Carbon hotkeys")
            usingFallback = true
            return fallback.register(bindings)
        }
        if usingFallback {
            fallback.unregisterAll()
            usingFallback = false
        }
        log.debug("Registered \(table.count) shortcuts on the event tap")
        return failed
    }

    public func unregisterAll() {
        state.update(table: [:], holdModifiers: [])
        fallback.unregisterAll()
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
        return counts.filter { !$0.key.isEmpty }.max { $0.value < $1.value }?.key ?? []
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
        self.port = port
        retainedState = retained
        state.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let state = self.state
        let thread = Thread {
            guard let runLoop = CFRunLoopGetCurrent() else { return }
            state.setRunLoop(runLoop)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.raff.ribbon.hotkeys"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.start()
        return true
    }

    private func stopTap() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop = state.runLoop { CFRunLoopStop(runLoop) }
        self.port = nil
        state.port = nil
        retainedState?.release()
        retainedState = nil
    }
}

/// Everything the tap thread touches, behind one lock.
final class HotkeyTapState {
    private let lock = NSLock()
    private var table: [KeyCombo: Command] = [:]
    private var holdModifiers: ModifierSet = []
    private var suspended = false
    private var holding = false
    private(set) var runLoop: CFRunLoop?
    var port: CFMachPort?
    /// Called on the main thread.
    var onCommand: ((Command) -> Void)?
    var onHold: ((Bool) -> Void)?

    func update(table: [KeyCombo: Command], holdModifiers: ModifierSet) {
        lock.lock()
        self.table = table
        self.holdModifiers = holdModifiers
        lock.unlock()
    }

    func setSuspended(_ value: Bool) {
        lock.lock()
        suspended = value
        lock.unlock()
    }

    func setRunLoop(_ runLoop: CFRunLoop) {
        lock.lock()
        self.runLoop = runLoop
        lock.unlock()
    }

    /// The command for a key press, or nil to let the event through. `swallowOnly` means
    /// "eat it but do nothing" (OS auto-repeat of a command that shouldn't repeat).
    func command(forKeyCode keyCode: UInt32, modifiers: ModifierSet, isRepeat: Bool) -> (command: Command, swallowOnly: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended, let command = table[KeyCombo(keyCode: keyCode, modifiers: modifiers)] else { return nil }
        return (command, isRepeat && !RepeatPolicy.isRepeatable(command))
    }

    /// Hold transitions of the primary modifier set (nil when unchanged).
    func holdTransition(for modifiers: ModifierSet) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        let held = !holdModifiers.isEmpty && modifiers.isSuperset(of: holdModifiers)
        guard held != holding else { return nil }
        holding = held
        return held
    }

    func reenable() {
        guard let port else { return }
        log.info("Hotkey tap was disabled by macOS; re-enabling")
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func dispatch(_ command: Command) {
        DispatchQueue.main.async { [weak self] in self?.onCommand?(command) }
    }

    func dispatchHold(_ held: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onHold?(held) }
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
        if let held = state.holdTransition(for: ModifierConversion.modifiers(from: event.flags)) {
            state.dispatchHold(held)
        }
        return passThrough
    case .keyDown:
        let keyCode = UInt32(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = ModifierConversion.modifiers(from: event.flags)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard let match = state.command(forKeyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat) else {
            return passThrough
        }
        if !match.swallowOnly { state.dispatch(match.command) }
        return nil
    default:
        return passThrough
    }
}
