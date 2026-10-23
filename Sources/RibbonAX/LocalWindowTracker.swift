import AppKit
import RibbonCore

/// Ribbon's own windows that take part in the strip (the settings window), so you can
/// cycle onto them like any other window. Accessibility calls from Ribbon's main thread
/// into Ribbon itself would wait on themselves, so these windows are read and moved
/// directly with AppKit instead. Main thread only.
final class LocalWindowTracker {
    /// Delivers events exactly like the AX path does.
    var emit: ((WindowEvent) -> Void)?
    /// True while the applier is moving the window (its own moves aren't reported).
    var isOwnMove: ((WindowID) -> Bool)?

    private struct Entry {
        weak var window: NSWindow?
        var tokens: [NSObjectProtocol]
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Windows the engine currently knows (shown and not yet closed).
    private var announced: Set<WindowID> = []
    /// A size AppKit refused (e.g. below the window's minimum) is reported this long after
    /// the move, once the engine no longer treats it as Ribbon's own move.
    private static let refusedSizeReportDelay: TimeInterval = 0.45

    deinit {
        for entry in entries.values { entry.tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    func register(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard entries[key] == nil else { return }
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ block: @escaping (NSWindow) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                if let window { block(window) }
            }
        }
        entries[key] = Entry(window: window, tokens: [
            on(NSWindow.didBecomeKeyNotification) { [weak self] in self?.becameKey($0) },
            on(NSWindow.willCloseNotification) { [weak self] in self?.closed($0) },
            on(NSWindow.didMoveNotification) { [weak self] in self?.frameChanged($0, resized: false) },
            on(NSWindow.didResizeNotification) { [weak self] in self?.frameChanged($0, resized: true) },
            on(NSWindow.didMiniaturizeNotification) { [weak self] in self?.report($0) { .windowMinimized($0) } },
            on(NSWindow.didDeminiaturizeNotification) { [weak self] in self?.report($0) { .windowDeminimized($0) } },
        ])
    }

    // MARK: Queries

    func contains(_ id: WindowID) -> Bool { window(for: id) != nil }

    func window(for id: WindowID) -> NSWindow? {
        entries.values.lazy.compactMap(\.window).first { WindowID(clamping: $0.windowNumber) == id }
    }

    func info(_ id: WindowID) -> WindowInfo? {
        window(for: id).map { Self.info(for: $0) }
    }

    /// Shown windows, for `currentWindows()`.
    func visibleInfos() -> [WindowInfo] {
        entries.values.compactMap(\.window).filter { $0.isVisible && announced.contains(Self.id(of: $0)) }.map(Self.info(for:))
    }

    /// Ribbon's key window, when Ribbon is the active app.
    func keyWindowID() -> WindowID? {
        guard NSApp.isActive, let key = NSApp.keyWindow, entries[ObjectIdentifier(key)] != nil else { return nil }
        return Self.id(of: key)
    }

    // MARK: Actions

    func focus(_ id: WindowID) {
        guard let window = window(for: id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Moves/resizes the window to an AX-space frame.
    func setFrame(_ id: WindowID, to frame: CGRect) {
        guard let window = window(for: id) else { return }
        let wanted = CoordinateSpace.flip(frame, primaryHeight: PrimaryScreen.height)
        window.setFrame(wanted, display: true)
        let got = window.frame
        guard abs(got.width - wanted.width) > 4 || abs(got.height - wanted.height) > 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refusedSizeReportDelay) { [weak self, weak window] in
            guard let self, let window, self.announced.contains(id) else { return }
            self.emit?(.windowResized(id, Self.axFrame(of: window)))
        }
    }

    // MARK: Notifications

    private func becameKey(_ window: NSWindow) {
        let id = Self.id(of: window)
        guard id != 0 else { return }
        if announced.insert(id).inserted {
            emit?(.windowCreated(Self.info(for: window)))
        }
        emit?(.windowFocused(id))
    }

    private func closed(_ window: NSWindow) {
        let id = Self.id(of: window)
        guard announced.remove(id) != nil else { return }
        emit?(.windowDestroyed(id))
    }

    private func frameChanged(_ window: NSWindow, resized: Bool) {
        let id = Self.id(of: window)
        guard announced.contains(id), !(isOwnMove?(id) ?? false) else { return }
        let frame = Self.axFrame(of: window)
        emit?(resized ? .windowResized(id, frame) : .windowMoved(id, frame))
    }

    private func report(_ window: NSWindow, _ event: (WindowID) -> WindowEvent) {
        let id = Self.id(of: window)
        guard announced.contains(id) else { return }
        emit?(event(id))
    }

    // MARK: Helpers

    static func id(of window: NSWindow) -> WindowID { WindowID(clamping: window.windowNumber) }

    static func axFrame(of window: NSWindow) -> CGRect {
        CoordinateSpace.flip(window.frame, primaryHeight: PrimaryScreen.height)
    }

    static func info(for window: NSWindow) -> WindowInfo {
        WindowInfo(
            id: id(of: window), pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: Bundle.main.bundleIdentifier, appName: "Ribbon", title: window.title,
            frame: axFrame(of: window), role: "AXWindow", subrole: "AXStandardWindow",
            isResizable: window.styleMask.contains(.resizable), isMinimized: window.isMiniaturized,
            isFullscreen: window.styleMask.contains(.fullScreen), isAppHidden: NSApp.isHidden, isRegularApp: true
        )
    }
}
