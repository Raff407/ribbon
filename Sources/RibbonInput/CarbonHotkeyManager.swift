import AppKit
import Carbon
import os
import RibbonCore

private let log = Logger(subsystem: "com.raff.ribbon", category: "Hotkeys")

/// Global hotkeys through Carbon's `RegisterEventHotKey` (works without the Input
/// Monitoring permission and can't be swallowed by the frontmost app).
///
/// * One Carbon hotkey per unique combo (signature `'RIBN'`), exclusive so a combo
///   already taken by another app fails instead of double-firing.
/// * Navigation and resize commands auto-repeat while held (0.35 s, then every 0.08 s).
/// * `modifierHoldHandler` reports ⌃⌥ going down/up via `.flagsChanged` monitors.
///
/// Main thread only. Carbon delivers application-target events on the main thread.
public final class CarbonHotkeyManager: HotkeyRegistering {
    public var commandHandler: ((Command) -> Void)?
    public var modifierHoldHandler: ((Bool) -> Void)? {
        didSet { updateFlagsMonitors() }
    }

    private struct Registration {
        let binding: KeyBinding
        let ref: EventHotKeyRef
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextHotkeyID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?
    private var isSuspended = false
    /// What `register(_:)` was last asked for; re-registered when a suspension ends.
    private var wantedBindings: [KeyBinding] = []

    private var repeatTimer: Timer?
    private var repeatSession: RepeatSession?

    private var holdTracker = ModifierHoldTracker()
    private var flagsMonitors: [Any] = []

    public init() {}

    deinit {
        repeatTimer?.invalidate()
        registrations.values.forEach { UnregisterEventHotKey($0.ref) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        flagsMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    // MARK: HotkeyRegistering

    @discardableResult
    public func register(_ bindings: [KeyBinding]) -> [KeyBinding] {
        releaseRegistrations()
        wantedBindings = bindings
        // While suspended nothing is registered (so the shortcut recorder can see every
        // key); the bindings are registered when the suspension ends.
        guard !isSuspended else { return [] }
        guard installEventHandlerIfNeeded() else { return bindings }
        var failed: [KeyBinding] = []
        for entry in HotkeyPlan.make(bindings) {
            switch entry {
            case .register(let binding):
                if !registerHotkey(binding) { failed.append(binding) }
            case .conflict(let binding):
                log.info("Combo of \(binding.command.id, privacy: .public) already bound to another command")
                failed.append(binding)
            case .rejected(let binding):
                log.info("Refusing unsafe global combo for \(binding.command.id, privacy: .public)")
                failed.append(binding)
            case .duplicate:
                break
            }
        }
        log.debug("Registered \(self.registrations.count) hotkeys, \(failed.count) failed")
        return failed
    }

    public func unregisterAll() {
        wantedBindings = []
        releaseRegistrations()
    }

    /// Unregisters every Carbon hotkey but remembers `wantedBindings`.
    private func releaseRegistrations() {
        stopRepeat()
        for (id, registration) in registrations {
            let status = UnregisterEventHotKey(registration.ref)
            if status != noErr {
                log.error("UnregisterEventHotKey(\(id)) failed: \(status)")
            }
        }
        registrations = [:]
    }

    /// Suspending really unregisters the hotkeys: Carbon would otherwise swallow the
    /// keystrokes before the shortcut recorder's keyDown monitor sees them.
    public func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            releaseRegistrations()
        } else {
            register(wantedBindings)
        }
    }

    // MARK: Carbon plumbing

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // Unretained: the handler is removed in deinit, so the pointer never dangles.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), carbonHotkeyEventHandler, specs.count, specs, userData, &ref
        )
        guard status == noErr, let ref else {
            log.error("InstallEventHandler failed: \(status)")
            return false
        }
        eventHandlerRef = ref
        return true
    }

    private func registerHotkey(_ binding: KeyBinding) -> Bool {
        let id = nextHotkeyID
        nextHotkeyID = nextHotkeyID == UInt32.max ? 1 : nextHotkeyID + 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.combo.keyCode,
            ModifierConversion.carbonFlags(from: binding.combo.modifiers),
            EventHotKeyID(signature: CarbonHotkeyID.signature, id: id),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        guard status == noErr, let ref else {
            log.info("RegisterEventHotKey failed for \(binding.command.id, privacy: .public): \(status)")
            return false
        }
        registrations[id] = Registration(binding: binding, ref: ref)
        return true
    }

    /// Called by the C trampoline on the main thread.
    fileprivate func handleHotkeyEvent(id: UInt32, pressed: Bool) {
        if pressed {
            handlePress(id)
        } else if repeatSession?.hotkeyID == id {
            stopRepeat()
        }
    }

    private func handlePress(_ id: UInt32) {
        guard !isSuspended, let registration = registrations[id] else { return }
        let command = registration.binding.command
        if RepeatPolicy.isRepeatable(command) {
            // A second "pressed" for the key we're already repeating is an OS auto-repeat.
            if repeatSession?.hotkeyID == id, repeatTimer != nil { return }
            startRepeat(id: id, combo: registration.binding.combo)
        } else {
            stopRepeat()
        }
        commandHandler?(command)
    }

    // MARK: Key repeat

    private func startRepeat(id: UInt32, combo: KeyCombo) {
        stopRepeat()
        repeatSession = RepeatSession(hotkeyID: id, combo: combo)
        let timer = Timer(
            fire: Date().addingTimeInterval(RepeatPolicy.initialDelay),
            interval: RepeatPolicy.interval,
            repeats: true
        ) { [weak self] _ in
            self?.repeatTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func repeatTick() {
        guard !isSuspended, let session = repeatSession, let registration = registrations[session.hotkeyID] else {
            stopRepeat()
            return
        }
        let keyDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(truncatingIfNeeded: session.combo.keyCode))
        let modifiers = ModifierConversion.modifiers(from: NSEvent.modifierFlags)
        let (next, keepGoing) = session.advanced(keyDown: keyDown, modifiers: modifiers)
        guard keepGoing else {
            stopRepeat()
            return
        }
        repeatSession = next
        commandHandler?(registration.binding.command)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatSession = nil
    }

    // MARK: Modifier hold

    private func updateFlagsMonitors() {
        if modifierHoldHandler == nil {
            removeFlagsMonitors()
        } else {
            installFlagsMonitorsIfNeeded()
        }
    }

    private func installFlagsMonitorsIfNeeded() {
        guard flagsMonitors.isEmpty else { return }
        // Global: other apps are frontmost. Local: our own windows (Settings) are key.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event.modifierFlags)
        }) {
            flagsMonitors.append(global)
        } else {
            log.error("Could not install the global flagsChanged monitor")
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event.modifierFlags)
            return event
        }) {
            flagsMonitors.append(local)
        }
    }

    private func removeFlagsMonitors() {
        flagsMonitors.forEach { NSEvent.removeMonitor($0) }
        flagsMonitors = []
        holdTracker = ModifierHoldTracker()
    }

    private func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let (next, transition) = holdTracker.updated(with: ModifierConversion.modifiers(from: flags))
        holdTracker = next
        if let transition {
            modifierHoldHandler?(transition)
        }
    }
}

// MARK: - Repeat session

/// State of one held, repeating hotkey. Carbon's "released" event is the primary stop
/// signal; these checks are a safety net so a lost release can't repeat forever.
struct RepeatSession: Equatable {
    let hotkeyID: UInt32
    let combo: KeyCombo
    /// Whether `CGEventSource.keyState` has been seen reporting the key down. Until it
    /// has, a "not down" answer is ambiguous (it may simply be unavailable), so it's
    /// ignored; once trusted, "not down" stops the repeat.
    private(set) var keyStateTrusted = false

    init(hotkeyID: UInt32, combo: KeyCombo) {
        self.hotkeyID = hotkeyID
        self.combo = combo
    }

    /// Returns the next session and whether to fire another repeat.
    func advanced(keyDown: Bool, modifiers: ModifierSet) -> (RepeatSession, Bool) {
        guard modifiers.isSuperset(of: combo.modifiers) else { return (self, false) }
        if keyStateTrusted && !keyDown { return (self, false) }
        var next = self
        next.keyStateTrusted = keyStateTrusted || keyDown
        return (next, true)
    }
}

// MARK: - C trampoline

/// Carbon event handler. `userData` is the unretained `CarbonHotkeyManager` that
/// installed it (it removes the handler in deinit). Must not capture context.
private func carbonHotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == CarbonHotkeyID.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let kind = GetEventKind(event)
    guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else {
        return OSStatus(eventNotHandledErr)
    }
    let pressed = kind == UInt32(kEventHotKeyPressed)
    let manager = Unmanaged<CarbonHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    if Thread.isMainThread {
        manager.handleHotkeyEvent(id: id, pressed: pressed)
    } else {
        DispatchQueue.main.async { [weak manager] in
            manager?.handleHotkeyEvent(id: id, pressed: pressed)
        }
    }
    return noErr
}
