import Foundation
import RibbonCore

/// Callbacks from the UI into the app. Built by the app target.
public struct AppActions {
    public var isEnabled: () -> Bool
    public var setEnabled: (Bool) -> Void
    public var gatherWindows: () -> Void
    public var relayout: () -> Void
    public var openSettings: () -> Void
    public var quit: () -> Void
    public var displays: () -> [DisplayInfo]
    /// Bindings that failed to register last time (shown as warnings in Shortcuts).
    public var failedBindings: () -> [KeyBinding]
    public var setHotkeysSuspended: (Bool) -> Void
    public var debugDump: () -> String
    public var managedWindowCount: () -> Int

    public init(
        isEnabled: @escaping () -> Bool, setEnabled: @escaping (Bool) -> Void,
        gatherWindows: @escaping () -> Void, relayout: @escaping () -> Void,
        openSettings: @escaping () -> Void, quit: @escaping () -> Void,
        displays: @escaping () -> [DisplayInfo], failedBindings: @escaping () -> [KeyBinding],
        setHotkeysSuspended: @escaping (Bool) -> Void, debugDump: @escaping () -> String,
        managedWindowCount: @escaping () -> Int
    ) {
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.gatherWindows = gatherWindows
        self.relayout = relayout
        self.openSettings = openSettings
        self.quit = quit
        self.displays = displays
        self.failedBindings = failedBindings
        self.setHotkeysSuspended = setHotkeysSuspended
        self.debugDump = debugDump
        self.managedWindowCount = managedWindowCount
    }
}
