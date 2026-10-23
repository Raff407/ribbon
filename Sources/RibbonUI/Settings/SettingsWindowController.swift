import AppKit
import RibbonCore
import SwiftUI

/// The "Ribbon Settings" window: one reusable `NSWindow` hosting `SettingsRootView`.
/// Created lazily on the first `show()`; closing only hides it.
///
/// Main thread only.
public final class SettingsWindowController {
    static let defaultSize = NSSize(width: 760, height: 560)
    static let autosaveName = "RibbonSettingsWindow"

    private let store: SettingsStore
    private let actions: AppActions
    private let recorder: ShortcutRecorderCoordinator
    private var window: NSWindow?
    /// Called once when the window is created (the app registers it as a strip window).
    public var windowCreatedHandler: ((NSWindow) -> Void)?
    private var closeObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    public init(store: SettingsStore, actions: AppActions) {
        self.store = store
        self.actions = actions
        self.recorder = ShortcutRecorderCoordinator(setHotkeysSuspended: actions.setHotkeysSuspended)
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        recorder.stop()
    }

    /// Brings the settings window to the front. While it's open Ribbon shows in the Dock
    /// and the app switcher like a normal app; closing it goes back to menu-bar only.
    public func show() {
        let window = self.window ?? makeWindow()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ribbon Settings"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.tabbingMode = .disallowed

        let root = SettingsRootView(store: store, actions: actions, recorder: recorder)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameAutosaveName(Self.autosaveName)

        // A recorder left running would keep every hotkey suspended.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.recorder.stop()
            NSApp.setActivationPolicy(.accessory)
        }
        // The recorder only sees keys while this window is key: losing key would otherwise
        // leave every hotkey suspended.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.recorder.stop()
        }
        self.window = window
        windowCreatedHandler?(window)
        return window
    }
}
