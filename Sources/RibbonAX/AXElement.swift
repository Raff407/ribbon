import ApplicationServices
import CoreGraphics
import Foundation
import RibbonCore

/// AX attribute names the SDK doesn't export as constants.
enum AXAttributeName {
    static let fullScreen = "AXFullScreen"
    /// Set by assistive apps; while true many apps animate their own frame changes, which
    /// makes every programmatic move very slow.
    static let enhancedUserInterface = "AXEnhancedUserInterface"
}

/// Per-app AX messaging timeout (seconds) so a hung app can't freeze Ribbon.
let axMessagingTimeout: Float = 0.25

/// Hashable identity of an AX element, using `CFEqual` / `CFHash` (which compare the
/// underlying remote element, not the Swift reference). Lets a destroyed element — which
/// can no longer be queried for its window id — be resolved through a reverse map.
struct AXElementKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

// MARK: - AXValue conversions

/// Conversions between raw CF attribute values and Swift values. Pure (no IPC).
enum AXValueConversion {
    /// True for the placeholders `AXUIElementCopyMultipleAttributeValues` puts in place of
    /// attributes that failed (an `AXValue` of type `.axError`, or `kCFNull`).
    static func isError(_ value: CFTypeRef) -> Bool {
        if CFGetTypeID(value) == CFNullGetTypeID() { return true }
        return axValue(value).map { AXValueGetType($0) == .axError } ?? false
    }

    static func point(_ value: CFTypeRef) -> CGPoint? {
        guard let raw = axValue(value), AXValueGetType(raw) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef) -> CGSize? {
        guard let raw = axValue(value), AXValueGetType(raw) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw, .cgSize, &size) ? size : nil
    }

    /// `CFBoolean` or `CFNumber` (some apps report booleans as numbers).
    static func bool(_ value: CFTypeRef) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    static func string(_ value: CFTypeRef) -> String? {
        value as? String
    }

    static func element(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func elements(_ value: CFTypeRef) -> [AXUIElement] {
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { element($0) }
    }

    static func value(_ point: CGPoint) -> AXValue? {
        var copy = point
        return AXValueCreate(.cgPoint, &copy)
    }

    static func value(_ size: CGSize) -> AXValue? {
        var copy = size
        return AXValueCreate(.cgSize, &copy)
    }

    private static func axValue(_ value: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

// MARK: - Typed attribute access

extension AXUIElement {
    /// One attribute plus the AX error (for callers that react to specific errors).
    func copyAttribute(_ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(self, name as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    func attribute(_ name: String) -> CFTypeRef? {
        copyAttribute(name).value
    }

    func string(_ name: String) -> String? { attribute(name).flatMap(AXValueConversion.string) }
    func bool(_ name: String) -> Bool? { attribute(name).flatMap(AXValueConversion.bool) }
    func point(_ name: String) -> CGPoint? { attribute(name).flatMap(AXValueConversion.point) }
    func size(_ name: String) -> CGSize? { attribute(name).flatMap(AXValueConversion.size) }
    func element(_ name: String) -> AXUIElement? { attribute(name).flatMap(AXValueConversion.element) }
    func elements(_ name: String) -> [AXUIElement] { attribute(name).map(AXValueConversion.elements) ?? [] }

    /// Several attributes in one IPC round trip. Attributes that failed are left out;
    /// a failed call yields an empty dictionary.
    func attributes(_ names: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(self, names as CFArray, [], &values)
        guard error == .success, let array = values as? [AnyObject], array.count == names.count else {
            return [:]
        }
        let pairs = zip(names, array).filter { !AXValueConversion.isError($0.1) }
        return Dictionary(pairs.map { ($0.0, $0.1 as CFTypeRef) }, uniquingKeysWith: { first, _ in first })
    }

    /// Position + size (AX space), nil if either is unreadable.
    func frame() -> CGRect? {
        let values = attributes([kAXPositionAttribute, kAXSizeAttribute])
        guard let origin = values[kAXPositionAttribute].flatMap(AXValueConversion.point),
              let size = values[kAXSizeAttribute].flatMap(AXValueConversion.size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(self, name as CFString, &settable)
        return error == .success && settable.boolValue
    }

    @discardableResult
    func setBool(_ name: String, _ value: Bool) -> AXError {
        let boolean: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(self, name as CFString, boolean)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        guard let value = AXValueConversion.value(point) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        guard let value = AXValueConversion.value(size) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    /// Owning process (local call, no IPC).
    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success && pid > 0 ? pid : nil
    }

    /// Window-server id via the private `_AXUIElementGetWindow`; nil for elements that
    /// aren't windows (or are already destroyed).
    var windowID: WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    func setMessagingTimeout(_ seconds: Float = axMessagingTimeout) {
        let error = AXUIElementSetMessagingTimeout(self, seconds)
        if error != .success {
            AXLog.windows.debug("AXUIElementSetMessagingTimeout failed: \(error.rawValue)")
        }
    }
}
