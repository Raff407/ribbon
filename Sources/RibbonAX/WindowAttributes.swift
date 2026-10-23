import AppKit
import ApplicationServices
import RibbonCore

/// Frame notifications need only these attributes. Keep unreadable fullscreen state
/// distinct from `false`, so a timeout cannot manufacture a fullscreen exit.
struct WindowFrameAttributes: Equatable {
    var frame: CGRect?
    var isFullscreen: Bool?

    static func parse(_ values: [String: CFTypeRef]) -> WindowFrameAttributes {
        let position = values[kAXPositionAttribute].flatMap(AXValueConversion.point)
        let size = values[kAXSizeAttribute].flatMap(AXValueConversion.size)
        let frame = position.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } }
        return WindowFrameAttributes(frame: frame, isFullscreen: values[AXAttributeName.fullScreen].flatMap(AXValueConversion.bool))
    }

    static func read(from element: AXUIElement, includingFullscreen: Bool = false) -> WindowFrameAttributes {
        var names = [kAXPositionAttribute, kAXSizeAttribute]
        if includingFullscreen { names.append(AXAttributeName.fullScreen) }
        return parse(element.attributes(names))
    }
}

/// What `WindowInfo` needs to know about the owning app.
struct AppMetadata: Equatable {
    var pid: ProcessID
    var bundleID: String?
    var appName: String
    var isHidden: Bool
    var isRegular: Bool

    init(pid: ProcessID, bundleID: String?, appName: String, isHidden: Bool, isRegular: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.isHidden = isHidden
        self.isRegular = isRegular
    }

    init(app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "",
            isHidden: app.isHidden,
            isRegular: app.activationPolicy == .regular
        )
    }

    /// Metadata for a pid, or nil when the process is gone.
    static func current(pid: ProcessID) -> AppMetadata? {
        NSRunningApplication(processIdentifier: pid).map(AppMetadata.init(app:))
    }
}

/// The AX attributes of one window, parsed from raw CF values. Pure value type: build it
/// with `parse` (no IPC) or `read(from:)` (live).
struct WindowAttributes: Equatable {
    var role: String?
    var subrole: String?
    var title: String?
    var position: CGPoint?
    var size: CGSize?
    var isMinimized: Bool
    var isFullscreen: Bool
    /// `AXUIElementIsAttributeSettable(kAXSizeAttribute)`.
    var sizeSettable: Bool
    var hasZoomButton: Bool
    /// `kAXEnabledAttribute` of the zoom button; nil when absent or unreadable.
    var zoomButtonEnabled: Bool?

    /// Attributes fetched in one `AXUIElementCopyMultipleAttributeValues` round trip.
    static let batchNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
        AXAttributeName.fullScreen, kAXZoomButtonAttribute,
    ]

    /// Parses the batch dictionary (attribute name → raw value; failed attributes absent)
    /// plus the two values that need separate calls.
    static func parse(_ values: [String: CFTypeRef], sizeSettable: Bool, zoomButtonEnabled: Bool?) -> WindowAttributes {
        WindowAttributes(
            role: values[kAXRoleAttribute].flatMap(AXValueConversion.string),
            subrole: values[kAXSubroleAttribute].flatMap(AXValueConversion.string),
            title: values[kAXTitleAttribute].flatMap(AXValueConversion.string),
            position: values[kAXPositionAttribute].flatMap(AXValueConversion.point),
            size: values[kAXSizeAttribute].flatMap(AXValueConversion.size),
            isMinimized: values[kAXMinimizedAttribute].flatMap(AXValueConversion.bool) ?? false,
            isFullscreen: values[AXAttributeName.fullScreen].flatMap(AXValueConversion.bool) ?? false,
            sizeSettable: sizeSettable,
            hasZoomButton: values[kAXZoomButtonAttribute].flatMap(AXValueConversion.element) != nil,
            zoomButtonEnabled: zoomButtonEnabled
        )
    }

    /// Live read (at most three IPC calls). Nil when the element can't be queried at all
    /// (destroyed, or the app timed out).
    static func read(from element: AXUIElement) -> WindowAttributes? {
        let values = element.attributes(batchNames)
        guard !values.isEmpty else { return nil }
        let zoomButton = values[kAXZoomButtonAttribute].flatMap(AXValueConversion.element)
        return parse(
            values,
            sizeSettable: element.isSettable(kAXSizeAttribute),
            zoomButtonEnabled: zoomButton?.bool(kAXEnabledAttribute)
        )
    }

    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Size settable and the zoom button, if present, not explicitly disabled.
    var isResizable: Bool {
        sizeSettable && (!hasZoomButton || zoomButtonEnabled != false)
    }

    /// Freshly created windows often report no subrole (or "AXUnknown") for a moment.
    var isSubroleUnresolved: Bool {
        subrole == nil || subrole == kAXUnknownSubrole
    }
}

enum WindowInfoFactory {
    /// Combines window attributes and app metadata; nil when the frame is unknown (a
    /// window Ribbon can't place is useless to the engine).
    static func make(id: WindowID, attributes: WindowAttributes, app: AppMetadata) -> WindowInfo? {
        guard let frame = attributes.frame else { return nil }
        return WindowInfo(
            id: id, pid: app.pid, bundleID: app.bundleID, appName: app.appName,
            title: attributes.title ?? "", frame: frame,
            role: attributes.role, subrole: attributes.subrole,
            isResizable: attributes.isResizable, isMinimized: attributes.isMinimized,
            isFullscreen: attributes.isFullscreen, isAppHidden: app.isHidden,
            isRegularApp: app.isRegular
        )
    }

    /// Live `WindowInfo` for an element (IPC).
    static func read(id: WindowID, element: AXUIElement, app: AppMetadata) -> WindowInfo? {
        WindowAttributes.read(from: element).flatMap { make(id: id, attributes: $0, app: app) }
    }
}
