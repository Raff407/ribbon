import AppKit
import Carbon
import os
import RibbonCore

private let log = Logger(subsystem: "com.raff.ribbon", category: "KeyNames")

/// Human-readable names for virtual key codes.
///
/// Character keys are translated through the *current keyboard layout*
/// (`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate`), so ⌃⌥ + the key at the
/// ANSI "Q" position shows "A" on AZERTY. Special keys (arrows, Return, F-keys, …) use a
/// fixed symbol table. Off the main thread (TIS is main-thread only) or when translation
/// fails, a US ANSI table is used.
public enum KeyNames {
    /// Human-readable key name for the current keyboard layout ("H", "←", "Space", "=").
    public static func name(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if Thread.isMainThread, let translated = LayoutTranslator.character(for: keyCode) {
            return translated
        }
        return ansiNames[keyCode] ?? "Key \(keyCode)"
    }

    /// "⌃⌥H" style string.
    public static func display(_ combo: KeyCombo) -> String {
        combo.modifiers.symbols + name(for: combo.keyCode)
    }

    /// Converts NSEvent modifier flags to a ModifierSet.
    public static func modifiers(from flags: NSEvent.ModifierFlags) -> ModifierSet {
        ModifierConversion.modifiers(from: flags)
    }

    // MARK: Tables

    /// Keys whose name doesn't depend on the layout.
    static let specialKeyNames: [UInt32: String] = {
        var table: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_Help: "Help", kVK_ANSI_KeypadClear: "⌧",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() {
            table[code] = "F\(index + 1)"
        }
        return Dictionary(uniqueKeysWithValues: table.map { (UInt32($0.key), $0.value) })
    }()

    /// US ANSI names, the fallback when the layout can't be queried.
    static let ansiNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O",
        0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x41: ".", 0x43: "*", 0x45: "+", 0x4B: "/", 0x4E: "-", 0x51: "=",
        0x52: "0", 0x53: "1", 0x54: "2", 0x55: "3", 0x56: "4", 0x57: "5", 0x58: "6", 0x59: "7",
        0x5B: "8", 0x5C: "9",
    ]

    /// Uppercases a single-character key name when that keeps it a single character
    /// ("a" → "A", but "ß" stays "ß" rather than becoming "SS").
    static func displayCase(_ raw: String) -> String {
        let upper = raw.uppercased()
        return upper.count == raw.count ? upper : raw
    }

    /// True when the translated string is something worth showing (not empty, not a
    /// control character such as the one F-keys or Return translate to).
    static func isPrintable(_ raw: String) -> Bool {
        let unwanted = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        return !raw.isEmpty && !raw.unicodeScalars.allSatisfy { unwanted.contains($0) }
    }
}

// MARK: - Layout translation

/// Wraps the Text Input Sources + Unicode key layout APIs. Main thread only.
enum LayoutTranslator {
    private static let maxLength = 4

    /// The unmodified character the key produces in the current layout, display-cased.
    static func character(for keyCode: UInt32) -> String? {
        guard keyCode <= HotkeyPlan.maxKeyCode, let source = layoutSource() else { return nil }
        return withExtendedLifetime(source) {
            guard let data = layoutData(of: source) else { return nil }
            return translate(keyCode: UInt16(keyCode), layoutData: data)
        }
    }

    /// The current keyboard layout; input methods without layout data (some CJK IMEs)
    /// fall back to the current ASCII-capable layout.
    private static func layoutSource() -> TISInputSource? {
        if let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           layoutData(of: current) != nil {
            return current
        }
        return TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    private static func layoutData(of source: TISInputSource) -> CFData? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func translate(keyCode: UInt16, layoutData: CFData) -> String? {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var result = translateOnce(layout: layout, keyCode: keyCode, deadKeyState: &deadKeyState)
        if (result ?? "").isEmpty, deadKeyState != 0 {
            // A dead key (e.g. ^ on French): press Space after it to get the accent itself.
            result = translateOnce(layout: layout, keyCode: UInt16(kVK_Space), deadKeyState: &deadKeyState)
        }
        guard let result, KeyNames.isPrintable(result) else { return nil }
        return KeyNames.displayCase(result)
    }

    private static func translateOnce(
        layout: UnsafePointer<UCKeyboardLayout>, keyCode: UInt16, deadKeyState: inout UInt32
    ) -> String? {
        var chars = [UniChar](repeating: 0, count: maxLength)
        var length = 0
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, maxLength, &length, &chars
        )
        guard status == noErr else {
            log.debug("UCKeyTranslate(\(keyCode)) failed: \(status)")
            return nil
        }
        return String(utf16CodeUnits: chars, count: min(length, maxLength))
    }
}
