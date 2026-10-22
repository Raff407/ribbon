import AppKit
import ApplicationServices

/// The AX notifications Ribbon listens to.
enum AXNotifications {
    /// Registered on the application element.
    static let app: [String] = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]
    /// Registered on each window element.
    static let window: [String] = [
        kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
    ]
}

/// The refcon handed to `AXObserver`. One retain (+1) is held for as long as the observer
/// is registered and released in `AppObserver.stop()`, so the pointer the C callback
/// receives is always valid; the weak back-reference means the box never keeps the
/// observer alive.
private final class ObserverContext {
    weak var owner: AppObserver?

    init(owner: AppObserver) {
        self.owner = owner
    }
}

/// C callback for every AX notification. Runs on the main run loop (the observer's
/// source is added there).
private func appObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    context.owner?.deliver(element: element, notification: notification as String)
}

/// One `AXObserver` for one app: app-level notifications plus per-window notifications.
/// Main thread only. Always call `stop()` (deinit does as a fallback) so the run-loop
/// source and the retained context are released.
final class AppObserver {
    /// `(pid, element, notification)`.
    typealias Handler = (pid_t, AXUIElement, String) -> Void

    enum StartResult: Equatable {
        case started
        /// The app isn't AX-ready yet (typical right after launch).
        case retryLater(AXError)
        /// Retrying won't help (AX disabled, notifications unsupported).
        case failed(AXError)
    }

    let pid: pid_t
    let app: NSRunningApplication
    let appElement: AXUIElement

    private let handler: Handler
    private var observer: AXObserver?
    private var context: Unmanaged<ObserverContext>?
    private var observedWindows: [AXElementKey: AXUIElement] = [:]

    init(app: NSRunningApplication, handler: @escaping Handler) {
        self.pid = app.processIdentifier
        self.app = app
        self.appElement = AXUIElementCreateApplication(app.processIdentifier)
        self.handler = handler
        appElement.setMessagingTimeout()
    }

    deinit {
        stop()
    }

    var isStarted: Bool { observer != nil }

    /// Creates the observer, registers the app-level notifications and adds the run-loop
    /// source. Idempotent.
    func start() -> StartResult {
        guard observer == nil else { return .started }
        var created: AXObserver?
        let createError = AXObserverCreate(pid, appObserverCallback, &created)
        guard createError == .success, let created else { return Self.classify(createError) }

        let retained = Unmanaged.passRetained(ObserverContext(owner: self))
        let refcon = retained.toOpaque()
        let windowCreated = Self.add(kAXWindowCreatedNotification, to: appElement, observer: created, refcon: refcon)
        guard windowCreated == .success else {
            retained.release()
            return Self.classify(windowCreated)
        }
        let focusChanged = Self.add(kAXFocusedWindowChangedNotification, to: appElement, observer: created, refcon: refcon)
        if focusChanged != .success {
            AXLog.observer.error("pid \(self.pid): focused-window notification failed (\(focusChanged.rawValue))")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        context = retained
        return .started
    }

    /// Registers the per-window notifications. False when the window can't be observed
    /// (no destroyed notification means Ribbon could never forget it).
    @discardableResult
    func observe(window: AXUIElement) -> Bool {
        guard let observer, let refcon = context?.toOpaque() else { return false }
        let key = AXElementKey(window)
        guard observedWindows[key] == nil else { return true }
        let results = AXNotifications.window.map { Self.add($0, to: window, observer: observer, refcon: refcon) }
        guard results.first == .success else {
            AXNotifications.window.forEach { AXObserverRemoveNotification(observer, window, $0 as CFString) }
            AXLog.observer.debug("pid \(self.pid): window not observable (\(results.first?.rawValue ?? 0))")
            return false
        }
        observedWindows[key] = window
        return true
    }

    /// Removes the per-window notifications (errors ignored: the element may be gone).
    func unobserve(window: AXUIElement) {
        let key = AXElementKey(window)
        guard let stored = observedWindows.removeValue(forKey: key), let observer else { return }
        AXNotifications.window.forEach { AXObserverRemoveNotification(observer, stored, $0 as CFString) }
    }

    /// Unregisters everything, removes the run-loop source and releases the context.
    /// Safe to call repeatedly.
    func stop() {
        guard let observer else { return }
        for window in observedWindows.values {
            AXNotifications.window.forEach { AXObserverRemoveNotification(observer, window, $0 as CFString) }
        }
        AXNotifications.app.forEach { AXObserverRemoveNotification(observer, appElement, $0 as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observedWindows = [:]
        self.observer = nil
        context?.release()
        context = nil
    }

    fileprivate func deliver(element: AXUIElement, notification: String) {
        handler(pid, element, notification)
    }

    // MARK: Helpers

    /// "Already registered" counts as success.
    private static func add(
        _ notification: String, to element: AXUIElement, observer: AXObserver, refcon: UnsafeMutableRawPointer
    ) -> AXError {
        let error = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        return error == .notificationAlreadyRegistered ? .success : error
    }

    private static func classify(_ error: AXError) -> StartResult {
        switch error {
        case .apiDisabled, .notificationUnsupported:
            return .failed(error)
        default:
            return .retryLater(error)
        }
    }
}
