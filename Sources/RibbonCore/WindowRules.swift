import CoreGraphics
import Foundation

public enum WindowDisposition: Equatable, Sendable {
    /// Goes on the strip.
    case tile
    /// Tracked but left where it is (dialogs, fixed-size windows, float rules).
    case float
    /// Not a window Ribbon cares about at all.
    case ignore
}

public enum WindowClassifier {
    /// Subroles that are dialog-like and float by default.
    public static let floatingSubroles: Set<String> = [
        "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow",
    ]

    /// Decides what to do with a window. Order:
    /// 1. `.ignore` when: role isn't "AXWindow" (nil role counts as AXWindow), subrole is
    ///    nil/"AXUnknown"/"" , minimized, fullscreen, app hidden, app not regular, either
    ///    dimension < 40pt, or a rule with `.ignore` matches the bundle id.
    /// 2. `.float` when `bundleID == ownBundleID` (Ribbon's own windows).
    /// 3. Rule `.float` → `.float`; rule `.tile` → `.tile` (overrides 4 and 5).
    /// 4. `.float` when `settings.behavior.floatDialogs` and the subrole is in
    ///    `floatingSubroles`.
    /// 5. `.float` when `settings.behavior.floatFixedSizeWindows` and `!isResizable`.
    /// 6. `.tile` when subrole is "AXStandardWindow"; otherwise `.float`.
    public static func classify(_ window: WindowInfo, settings: RibbonSettings, ownBundleID: String?) -> WindowDisposition {
        let rule = settings.rule(for: window.bundleID)
        if isIgnorable(window) || rule?.action == .ignore { return .ignore }
        if let own = ownBundleID, window.bundleID == own { return .float }
        switch rule?.action {
        case .float: return .float
        case .tile: return .tile
        case .ignore, nil: break
        }
        if settings.behavior.floatDialogs, let subrole = window.subrole, floatingSubroles.contains(subrole) {
            return .float
        }
        if settings.behavior.floatFixedSizeWindows && !window.isResizable { return .float }
        return window.subrole == "AXStandardWindow" ? .tile : .float
    }

    static func isIgnorable(_ window: WindowInfo) -> Bool {
        let minimumSide: CGFloat = 40
        if let role = window.role, role != "AXWindow" { return true }
        guard let subrole = window.subrole, !subrole.isEmpty, subrole != "AXUnknown" else { return true }
        return window.isMinimized || window.isFullscreen || window.isAppHidden || !window.isRegularApp
            || window.frame.width < minimumSide || window.frame.height < minimumSide
    }
}
