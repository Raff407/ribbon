import Foundation

// MARK: - Keys

public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)

    /// ⌃⌥, the default prefix for every Ribbon shortcut.
    public static let hyperLite: ModifierSet = [.control, .option]

    /// Symbols in the conventional macOS order: ⌃⌥⇧⌘.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// Virtual key codes (Carbon `kVK_*`, which are physical key positions on an ANSI layout).
public enum KeyCode {
    public static let a: UInt32 = 0x00, s: UInt32 = 0x01, d: UInt32 = 0x02, f: UInt32 = 0x03
    public static let h: UInt32 = 0x04, g: UInt32 = 0x05, z: UInt32 = 0x06, x: UInt32 = 0x07
    public static let c: UInt32 = 0x08, v: UInt32 = 0x09, b: UInt32 = 0x0B, q: UInt32 = 0x0C
    public static let w: UInt32 = 0x0D, e: UInt32 = 0x0E, r: UInt32 = 0x0F, y: UInt32 = 0x10
    public static let t: UInt32 = 0x11, one: UInt32 = 0x12, two: UInt32 = 0x13, three: UInt32 = 0x14
    public static let four: UInt32 = 0x15, six: UInt32 = 0x16, five: UInt32 = 0x17, equal: UInt32 = 0x18
    public static let nine: UInt32 = 0x19, seven: UInt32 = 0x1A, minus: UInt32 = 0x1B, eight: UInt32 = 0x1C
    public static let zero: UInt32 = 0x1D, rightBracket: UInt32 = 0x1E, o: UInt32 = 0x1F, u: UInt32 = 0x20
    public static let leftBracket: UInt32 = 0x21, i: UInt32 = 0x22, p: UInt32 = 0x23, returnKey: UInt32 = 0x24
    public static let l: UInt32 = 0x25, j: UInt32 = 0x26, quote: UInt32 = 0x27, k: UInt32 = 0x28
    public static let semicolon: UInt32 = 0x29, backslash: UInt32 = 0x2A, comma: UInt32 = 0x2B, slash: UInt32 = 0x2C
    public static let n: UInt32 = 0x2D, m: UInt32 = 0x2E, period: UInt32 = 0x2F, tab: UInt32 = 0x30
    public static let space: UInt32 = 0x31, grave: UInt32 = 0x32, delete: UInt32 = 0x33, escape: UInt32 = 0x35
    public static let leftArrow: UInt32 = 0x7B, rightArrow: UInt32 = 0x7C, downArrow: UInt32 = 0x7D, upArrow: UInt32 = 0x7E
    public static let home: UInt32 = 0x73, end: UInt32 = 0x77, pageUp: UInt32 = 0x74, pageDown: UInt32 = 0x79

    /// Number row key codes for 1...9 (index 0 = key "1").
    public static let digits: [UInt32] = [one, two, three, four, five, six, seven, eight, nine]
}

public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ModifierSet

    public init(keyCode: UInt32, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct KeyBinding: Codable, Hashable, Sendable {
    public var command: Command
    public var combo: KeyCombo

    public init(command: Command, combo: KeyCombo) {
        self.command = command
        self.combo = combo
    }
}

/// Ready-made shortcut sets (Settings → Shortcuts → Use Preset).
public enum ShortcutPreset: String, CaseIterable, Sendable {
    /// ⌥ + letters. Arrows and number keys stay free, so ⌥-arrow word jumps and ⌥-number
    /// characters (# and € on UK layouts) keep working; the accent dead keys ⌥E/U/I/N/`
    /// aren't used either.
    case option
    /// The original set: ⌃⌥ + letters, arrows and numbers.
    case controlOption

    public var title: String {
        switch self {
        case .option: return "Option (⌥) + letters"
        case .controlOption: return "Control-Option (⌃⌥) + letters, arrows and numbers"
        }
    }
}

public enum DefaultBindings {
    /// The fresh-install shortcut set.
    public static let all: [KeyBinding] = preset(.option)

    public static func preset(_ preset: ShortcutPreset) -> [KeyBinding] {
        switch preset {
        case .option: return optionSet
        case .controlOption: return controlOptionSet
        }
    }

    private static func b(_ c: Command, _ k: UInt32, _ mods: ModifierSet) -> KeyBinding {
        KeyBinding(command: c, combo: KeyCombo(keyCode: k, modifiers: mods))
    }

    private static let optionSet: [KeyBinding] = {
        let m: ModifierSet = .option
        let ms: ModifierSet = [.option, .shift]
        return [
            b(.focus(.left), KeyCode.h, m), b(.focus(.down), KeyCode.j, m),
            b(.focus(.up), KeyCode.k, m), b(.focus(.right), KeyCode.l, m),
            b(.move(.left), KeyCode.h, ms), b(.move(.down), KeyCode.j, ms),
            b(.move(.up), KeyCode.k, ms), b(.move(.right), KeyCode.l, ms),
            b(.cycleWidth, KeyCode.r, m), b(.cycleWidthBackward, KeyCode.r, ms),
            b(.toggleFullWidth, KeyCode.f, m), b(.centreColumn, KeyCode.c, m),
            b(.wider, KeyCode.equal, m), b(.narrower, KeyCode.minus, m),
            b(.stackIntoLeft, KeyCode.leftBracket, m), b(.stackIntoRight, KeyCode.rightBracket, m),
            b(.popOutLeft, KeyCode.leftBracket, ms), b(.popOutRight, KeyCode.rightBracket, ms),
            b(.toggleFloat, KeyCode.t, m), b(.toggleTabbed, KeyCode.t, ms),
            b(.pinLeft, KeyCode.p, m), b(.pinRight, KeyCode.p, ms),
            b(.sendToNextDisplay, KeyCode.m, m),
            b(.toggleEnabled, KeyCode.q, m), b(.gatherWindows, KeyCode.g, ms),
            b(.openSettings, KeyCode.comma, m),
        ]
    }()

    /// Ribbon's first default set, kept as a preset (and to recognise untouched old installs).
    private static let controlOptionSet: [KeyBinding] = {
        let m = ModifierSet.hyperLite
        let ms: ModifierSet = [.control, .option, .shift]
        let mc: ModifierSet = [.control, .option, .command]
        let mcs: ModifierSet = [.control, .option, .command, .shift]
        var list: [KeyBinding] = [
            b(.focus(.left), KeyCode.h, m), b(.focus(.down), KeyCode.j, m),
            b(.focus(.up), KeyCode.k, m), b(.focus(.right), KeyCode.l, m),
            b(.focus(.left), KeyCode.leftArrow, m), b(.focus(.down), KeyCode.downArrow, m),
            b(.focus(.up), KeyCode.upArrow, m), b(.focus(.right), KeyCode.rightArrow, m),
            b(.focusFirst, KeyCode.leftArrow, mc), b(.focusLast, KeyCode.rightArrow, mc),
            b(.focusFirst, KeyCode.h, mc), b(.focusLast, KeyCode.l, mc),
            b(.move(.left), KeyCode.h, ms), b(.move(.down), KeyCode.j, ms),
            b(.move(.up), KeyCode.k, ms), b(.move(.right), KeyCode.l, ms),
            b(.move(.left), KeyCode.leftArrow, ms), b(.move(.down), KeyCode.downArrow, ms),
            b(.move(.up), KeyCode.upArrow, ms), b(.move(.right), KeyCode.rightArrow, ms),
            b(.moveFirst, KeyCode.leftArrow, mcs), b(.moveLast, KeyCode.rightArrow, mcs),
            b(.sendToNextDisplay, KeyCode.n, m),
            b(.cycleWidth, KeyCode.r, m), b(.cycleWidthBackward, KeyCode.r, ms),
            b(.toggleFullWidth, KeyCode.f, m), b(.centreColumn, KeyCode.c, m),
            b(.wider, KeyCode.equal, m), b(.narrower, KeyCode.minus, m),
            b(.taller, KeyCode.equal, ms), b(.shorter, KeyCode.minus, ms),
            b(.equalizeHeights, KeyCode.zero, m),
            b(.pinLeft, KeyCode.p, m), b(.pinRight, KeyCode.p, ms),
            b(.stackIntoLeft, KeyCode.leftBracket, m), b(.stackIntoRight, KeyCode.rightBracket, m),
            b(.popOutLeft, KeyCode.leftBracket, ms), b(.popOutRight, KeyCode.rightBracket, ms),
            b(.toggleTabbed, KeyCode.t, ms), b(.toggleFloat, KeyCode.t, m),
            b(.toggleEnabled, KeyCode.q, m), b(.gatherWindows, KeyCode.g, ms),
            b(.showIndicator, KeyCode.space, m), b(.openSettings, KeyCode.comma, m),
        ]
        for n in 1...9 {
            list.append(b(.focusColumn(n), KeyCode.digits[n - 1], m))
        }
        return list
    }()
}

// MARK: - Settings groups

public struct AnimationSettings: Equatable, Codable, Sendable {
    public var enabled: Bool
    /// 0.5 ... 3; multiplies spring speed.
    public var speed: Double
    /// Not persisted: only `enabled` and `speed` are user settings, so tuning the default
    /// spring reaches existing installs.
    public var spring: SpringParameters

    private enum CodingKeys: String, CodingKey {
        case enabled, speed
    }

    public init(enabled: Bool = true, speed: Double = 1, spring: SpringParameters = .default) {
        self.enabled = enabled
        self.speed = speed
        self.spring = spring
    }

    public var effectiveSpring: SpringParameters { spring.withSpeed(speed) }
}

public struct AppearanceSettings: Equatable, Codable, Sendable {
    public var focusBorderEnabled: Bool
    public var focusBorderWidth: Double
    /// "#RRGGBB" or "#RRGGBBAA".
    public var focusBorderColorHex: String
    public var focusBorderCornerRadius: Double
    public var dimInactiveEnabled: Bool
    /// 0 ... 0.8 opacity of the dimming layer.
    public var dimAmount: Double
    public var indicatorEnabled: Bool
    /// Seconds the strip indicator stays up after the last navigation.
    public var indicatorDuration: Double
    public var tabBarsEnabled: Bool

    public init(
        focusBorderEnabled: Bool = false,
        focusBorderWidth: Double = 4,
        focusBorderColorHex: String = "#3D8BFF",
        focusBorderCornerRadius: Double = 10,
        dimInactiveEnabled: Bool = false,
        dimAmount: Double = 0.25,
        indicatorEnabled: Bool = true,
        indicatorDuration: Double = 1.2,
        tabBarsEnabled: Bool = true
    ) {
        self.focusBorderEnabled = focusBorderEnabled
        self.focusBorderWidth = focusBorderWidth
        self.focusBorderColorHex = focusBorderColorHex
        self.focusBorderCornerRadius = focusBorderCornerRadius
        self.dimInactiveEnabled = dimInactiveEnabled
        self.dimAmount = dimAmount
        self.indicatorEnabled = indicatorEnabled
        self.indicatorDuration = indicatorDuration
        self.tabBarsEnabled = tabBarsEnabled
    }
}

public struct TrackpadSettings: Equatable, Codable, Sendable {
    /// Scroll the strip with a horizontal scroll (two-finger swipe / mouse wheel with
    /// shift) while holding `scrollModifiers`.
    public var scrollWithModifierEnabled: Bool
    public var scrollModifiers: ModifierSet
    /// Scroll the strip with a bare multi-finger horizontal swipe (private
    /// MultitouchSupport framework). Off by default: macOS uses 3/4-finger swipes for
    /// Spaces unless the user changes Trackpad settings.
    public var swipeEnabled: Bool
    /// 3 or 4.
    public var swipeFingers: Int
    /// Multiplier on gesture distance (1 = one-to-one with the fingers).
    public var sensitivity: Double
    /// Reverse the scroll direction.
    public var invertDirection: Bool

    public init(
        scrollWithModifierEnabled: Bool = true,
        scrollModifiers: ModifierSet = .hyperLite,
        swipeEnabled: Bool = false,
        swipeFingers: Int = 3,
        sensitivity: Double = 1,
        invertDirection: Bool = false
    ) {
        self.scrollWithModifierEnabled = scrollWithModifierEnabled
        self.scrollModifiers = scrollModifiers
        self.swipeEnabled = swipeEnabled
        self.swipeFingers = swipeFingers
        self.sensitivity = sensitivity
        self.invertDirection = invertDirection
    }
}

public enum NewWindowPosition: String, Codable, CaseIterable, Sendable {
    case afterFocused
    case end
}

public struct BehaviorSettings: Equatable, Codable, Sendable {
    public var newWindowPosition: NewWindowPosition
    public var focusFollowsMouse: Bool
    public var mouseFollowsFocus: Bool
    public var restoreSession: Bool
    /// Windows that can't be resized (e.g. Calculator) float automatically.
    public var floatFixedSizeWindows: Bool
    /// Dialogs, sheets-as-windows, Quick Look and floating panels float automatically.
    public var floatDialogs: Bool
    /// Seconds between background consistency sweeps (0 = off).
    public var reconcileInterval: Double
    /// Dragging the edge between two visible windows resizes both, like a divider.
    public var resizeAdjustsNeighbour: Bool

    public init(
        newWindowPosition: NewWindowPosition = .afterFocused,
        focusFollowsMouse: Bool = false,
        mouseFollowsFocus: Bool = false,
        restoreSession: Bool = true,
        floatFixedSizeWindows: Bool = true,
        floatDialogs: Bool = true,
        reconcileInterval: Double = 3,
        resizeAdjustsNeighbour: Bool = true
    ) {
        self.newWindowPosition = newWindowPosition
        self.focusFollowsMouse = focusFollowsMouse
        self.mouseFollowsFocus = mouseFollowsFocus
        self.restoreSession = restoreSession
        self.floatFixedSizeWindows = floatFixedSizeWindows
        self.floatDialogs = floatDialogs
        self.reconcileInterval = reconcileInterval
        self.resizeAdjustsNeighbour = resizeAdjustsNeighbour
    }
}

public enum AppRuleAction: String, Codable, CaseIterable, Sendable {
    /// Never tile this app's windows.
    case float
    /// Tile even windows the heuristics would float (fixed-size, dialogs).
    case tile
    /// Leave the app entirely alone (not even floating-window tracking).
    case ignore
}

public struct AppRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    /// Display name, for the settings list.
    public var appName: String
    public var action: AppRuleAction

    public var id: String { bundleID }

    public init(bundleID: String, appName: String, action: AppRuleAction) {
        self.bundleID = bundleID
        self.appName = appName
        self.action = action
    }
}

// MARK: - Root

/// Every user setting. Persisted as JSON. Decoding must be forward/backward compatible:
/// every field (here and in the nested groups) falls back to its default when missing,
/// and unknown keys / unknown command ids in `bindings` are ignored, so adding settings
/// never wipes a user's configuration.
public struct RibbonSettings: Equatable, Codable, Sendable {
    public var layout: LayoutConfig
    public var animation: AnimationSettings
    public var appearance: AppearanceSettings
    public var trackpad: TrackpadSettings
    public var behavior: BehaviorSettings
    public var rules: [AppRule]
    /// Display UUIDs Ribbon leaves alone.
    public var disabledDisplays: [String]
    public var bindings: [KeyBinding]
    /// Which default shortcut scheme the saved bindings come from. 1 = the original ⌃⌥ set
    /// (settings saved before this field existed), 2 = the ⌥ set. Untouched revision-1
    /// bindings are moved to the current defaults when loaded.
    public var bindingsRevision: Int

    public static let currentBindingsRevision = 2

    public init(
        layout: LayoutConfig = .default,
        animation: AnimationSettings = AnimationSettings(),
        appearance: AppearanceSettings = AppearanceSettings(),
        trackpad: TrackpadSettings = TrackpadSettings(),
        behavior: BehaviorSettings = BehaviorSettings(),
        rules: [AppRule] = [],
        disabledDisplays: [String] = [],
        bindings: [KeyBinding] = DefaultBindings.all,
        bindingsRevision: Int = RibbonSettings.currentBindingsRevision
    ) {
        self.layout = layout
        self.animation = animation
        self.appearance = appearance
        self.trackpad = trackpad
        self.behavior = behavior
        self.rules = rules
        self.disabledDisplays = disabledDisplays
        self.bindings = bindings
        self.bindingsRevision = bindingsRevision
    }

    public static let defaults = RibbonSettings()

    public func rule(for bundleID: String?) -> AppRule? {
        guard let bundleID else { return nil }
        return rules.first { $0.bundleID == bundleID }
    }

    /// Bindings grouped by combo; a combo bound to more than one command is a conflict.
    public var conflictingCombos: Set<KeyCombo> {
        var seen: [KeyCombo: Int] = [:]
        for b in bindings { seen[b.combo, default: 0] += 1 }
        return Set(seen.filter { $0.value > 1 }.keys)
    }
}

// MARK: - Tolerant decoding
//
// Every settings group decodes field by field, falling back to the default for anything
// missing or malformed, so adding a setting (or a bad hand edit) never wipes the rest.

extension KeyedDecodingContainer {
    /// The decoded value for `key`, or `fallback` when it's missing or can't be decoded.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// Decodes an array element by element, skipping elements that fail (e.g. bindings for
/// a command id this version doesn't know).
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(elements: [Element]) {
        self.elements = elements
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(AnyDecodable.self)
            }
        }
        elements = result
    }
}

/// Consumes one value of any shape.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

extension AnimationSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnimationSettings()
        self.init(enabled: c.value(.enabled, default: d.enabled), speed: c.value(.speed, default: d.speed))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(speed, forKey: .speed)
    }
}

extension AppearanceSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        self.init(
            focusBorderEnabled: c.value(.focusBorderEnabled, default: d.focusBorderEnabled),
            focusBorderWidth: c.value(.focusBorderWidth, default: d.focusBorderWidth),
            focusBorderColorHex: c.value(.focusBorderColorHex, default: d.focusBorderColorHex),
            focusBorderCornerRadius: c.value(.focusBorderCornerRadius, default: d.focusBorderCornerRadius),
            dimInactiveEnabled: c.value(.dimInactiveEnabled, default: d.dimInactiveEnabled),
            dimAmount: c.value(.dimAmount, default: d.dimAmount),
            indicatorEnabled: c.value(.indicatorEnabled, default: d.indicatorEnabled),
            indicatorDuration: c.value(.indicatorDuration, default: d.indicatorDuration),
            tabBarsEnabled: c.value(.tabBarsEnabled, default: d.tabBarsEnabled)
        )
    }
}

extension TrackpadSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TrackpadSettings()
        self.init(
            scrollWithModifierEnabled: c.value(.scrollWithModifierEnabled, default: d.scrollWithModifierEnabled),
            scrollModifiers: c.value(.scrollModifiers, default: d.scrollModifiers),
            swipeEnabled: c.value(.swipeEnabled, default: d.swipeEnabled),
            swipeFingers: c.value(.swipeFingers, default: d.swipeFingers),
            sensitivity: c.value(.sensitivity, default: d.sensitivity),
            invertDirection: c.value(.invertDirection, default: d.invertDirection)
        )
    }
}

extension BehaviorSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BehaviorSettings()
        self.init(
            newWindowPosition: c.value(.newWindowPosition, default: d.newWindowPosition),
            focusFollowsMouse: c.value(.focusFollowsMouse, default: d.focusFollowsMouse),
            mouseFollowsFocus: c.value(.mouseFollowsFocus, default: d.mouseFollowsFocus),
            restoreSession: c.value(.restoreSession, default: d.restoreSession),
            floatFixedSizeWindows: c.value(.floatFixedSizeWindows, default: d.floatFixedSizeWindows),
            floatDialogs: c.value(.floatDialogs, default: d.floatDialogs),
            reconcileInterval: c.value(.reconcileInterval, default: d.reconcileInterval),
            resizeAdjustsNeighbour: c.value(.resizeAdjustsNeighbour, default: d.resizeAdjustsNeighbour)
        )
    }
}

extension RibbonSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RibbonSettings()
        self.init(
            layout: c.value(.layout, default: d.layout),
            animation: c.value(.animation, default: d.animation),
            appearance: c.value(.appearance, default: d.appearance),
            trackpad: c.value(.trackpad, default: d.trackpad),
            behavior: c.value(.behavior, default: d.behavior),
            rules: c.value(.rules, default: LossyArray<AppRule>(elements: d.rules)).elements,
            disabledDisplays: c.value(.disabledDisplays, default: d.disabledDisplays),
            bindings: RibbonSettings.migratedBindings(
                c.value(.bindings, default: LossyArray<KeyBinding>(elements: d.bindings)).elements,
                revision: c.value(.bindingsRevision, default: 1)
            )
        )
    }

    /// Settings saved with the untouched original ⌃⌥ defaults get today's defaults; any
    /// customised set is kept as it is.
    static func migratedBindings(_ bindings: [KeyBinding], revision: Int) -> [KeyBinding] {
        guard revision < currentBindingsRevision, bindings == DefaultBindings.preset(.controlOption) else { return bindings }
        return DefaultBindings.all
    }
}
