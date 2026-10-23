import AppKit
import Carbon
import CoreGraphics
import RibbonCore

// Pure helpers shared by the hotkey manager and the scroll tap: modifier conversions,
// the registration plan (which bindings get a Carbon hotkey) and the key-repeat policy.
// Nothing here touches global state, so it is all trivially testable.

// MARK: - Modifier conversions

enum ModifierConversion {
    /// ModifierSet → Carbon `controlKey|optionKey|shiftKey|cmdKey` bits for
    /// `RegisterEventHotKey`.
    static func carbonFlags(from modifiers: ModifierSet) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    /// Quartz event flags (event taps) → ModifierSet. Caps Lock, Fn and the numeric-pad
    /// bit are ignored.
    static func modifiers(from flags: CGEventFlags) -> ModifierSet {
        var set: ModifierSet = []
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        return set
    }

    /// AppKit modifier flags → ModifierSet (device-dependent bits are ignored).
    static func modifiers(from flags: NSEvent.ModifierFlags) -> ModifierSet {
        let clean = flags.intersection(.deviceIndependentFlagsMask)
        var set: ModifierSet = []
        if clean.contains(.control) { set.insert(.control) }
        if clean.contains(.option) { set.insert(.option) }
        if clean.contains(.shift) { set.insert(.shift) }
        if clean.contains(.command) { set.insert(.command) }
        return set
    }
}

// MARK: - Registration plan

/// What to do with each binding passed to `CarbonHotkeyManager.register(_:)`.
enum HotkeyPlanEntry: Equatable {
    /// First binding for this combo: register it with Carbon.
    case register(KeyBinding)
    /// The combo is already claimed by an earlier binding for a *different* command
    /// (first wins) — reported as failed.
    case conflict(KeyBinding)
    /// Exact repeat of an earlier binding (same command, same combo) — silently skipped.
    case duplicate(KeyBinding)
    /// Unsafe as a global hotkey (no ⌃/⌥/⌘ on a typing key would swallow normal
    /// typing system-wide) — reported as failed.
    case rejected(KeyBinding)
}

enum HotkeyPlan {
    /// Function keys F1–F20 are fine as global hotkeys even without ⌃/⌥/⌘.
    static let functionKeyCodes: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    /// Highest virtual key code a keyboard produces (`kVK_*` codes are 7-bit).
    static let maxKeyCode: UInt32 = 0x7F

    /// True when the combo can be registered system-wide without hijacking typing.
    static func isSafeGlobalCombo(_ combo: KeyCombo) -> Bool {
        guard combo.keyCode <= maxKeyCode else { return false }
        let strong: ModifierSet = [.control, .option, .command]
        return !combo.modifiers.isDisjoint(with: strong) || functionKeyCodes.contains(combo.keyCode)
    }

    /// Classifies every binding, in input order. One combo bound to several commands:
    /// the first wins and the rest are conflicts.
    static func make(_ bindings: [KeyBinding]) -> [HotkeyPlanEntry] {
        var claimed: [KeyCombo: Command] = [:]
        return bindings.map { binding in
            guard isSafeGlobalCombo(binding.combo) else { return .rejected(binding) }
            if let owner = claimed[binding.combo] {
                return owner == binding.command ? .duplicate(binding) : .conflict(binding)
            }
            claimed[binding.combo] = binding.command
            return .register(binding)
        }
    }
}

// MARK: - Key repeat

/// Which commands auto-repeat while their hotkey is held, and how fast.
enum RepeatPolicy {
    /// Delay between the press and the first repeat.
    static let initialDelay: TimeInterval = 0.35
    /// Delay between subsequent repeats.
    static let interval: TimeInterval = 0.08

    static func isRepeatable(_ command: Command) -> Bool {
        switch command {
        case .focus, .move, .wider, .narrower, .taller, .shorter:
            return true
        default:
            return false
        }
    }
}

// MARK: - Modifier hold

/// Tracks the configured shortcut prefix and reports only transitions.
struct ModifierHoldTracker: Equatable {
    /// Extra modifiers do not cancel a hold; an empty prefix never engages.
    var prefix: ModifierSet = .hyperLite

    private(set) var isHeld = false

    /// Returns the updated tracker and the transition to report (nil when unchanged).
    func updated(with modifiers: ModifierSet) -> (ModifierHoldTracker, Bool?) {
        let held = !prefix.isEmpty && modifiers.isSuperset(of: prefix)
        guard held != isHeld else { return (self, nil) }
        var next = self
        next.isHeld = held
        return (next, held)
    }
}

// MARK: - Carbon hotkey ids

enum CarbonHotkeyID {
    /// `'RIBN'` as a FourCharCode.
    static let signature: OSType = {
        "RIBN".utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()
}
