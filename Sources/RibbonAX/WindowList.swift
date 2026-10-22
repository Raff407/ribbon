import CoreGraphics
import Foundation
import RibbonCore

/// Window-server window lists (`CGWindowListCopyWindowInfo`). Needs no Accessibility
/// permission and is cheap enough to call every few seconds.
enum WindowList {
    /// Normal application windows live on layer 0 (menus, the Dock, overlays are higher).
    static let normalLayer = 0

    /// Every window on any Space, minus desktop elements.
    static func existingWindowIDs() -> Set<WindowID> {
        // Any layer: a window set to "float on top" moves off layer 0 but still exists.
        windowIDs(options: [.optionAll, .excludeDesktopElements], layer: nil)
    }

    /// Windows currently on screen on any display.
    static func onScreenWindowIDs() -> Set<WindowID> {
        windowIDs(options: [.optionOnScreenOnly])
    }

    /// Empty when the window server call fails (callers treat empty as "unknown").
    static func windowIDs(options: CGWindowListOption, layer: Int? = normalLayer) -> Set<WindowID> {
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) else {
            AXLog.windows.error("CGWindowListCopyWindowInfo returned nil")
            return []
        }
        let list = (raw as NSArray) as? [[String: Any]] ?? []
        return windowIDs(from: list, layer: layer)
    }

    /// Pure: ids of the entries on `layer` (any layer when nil). Entries missing a needed
    /// key are skipped.
    static func windowIDs(from list: [[String: Any]], layer: Int?) -> Set<WindowID> {
        let numberKey = kCGWindowNumber as String
        let layerKey = kCGWindowLayer as String
        let ids = list.compactMap { entry -> WindowID? in
            if let layer, (entry[layerKey] as? NSNumber)?.intValue != layer { return nil }
            guard let number = (entry[numberKey] as? NSNumber)?.int64Value, number > 0,
                  number <= Int64(WindowID.max) else { return nil }
            return WindowID(number)
        }
        return Set(ids)
    }
}
