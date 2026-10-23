import AppKit
import ApplicationServices
import QuartzCore
import RibbonCore

/// The Accessibility-backed `WindowSource`: observes every regular app, keeps a registry
/// of window elements, and turns AX + NSWorkspace notifications into `WindowEvent`s.
/// Main thread only.
public final class AXWindowSource: WindowSource {
    public var eventHandler: ((WindowEvent) -> Void)?

    private let ownPID: pid_t
    private var observers: [pid_t: AppObserver] = [:]
    private var registry = WindowRegistry()
    private var workspaceTokens: [NSObjectProtocol] = []
    private var isStarted = false

    /// Windows Ribbon itself is moving, until when. Their move/resize notifications are
    /// coalesced into one trailing read after the motion stops, instead of one AX round
    /// trip per animation frame.
    private var ownMoveUntil: [WindowID: CFTimeInterval] = [:]
    /// Windows whose frame changed and still needs reading (value: was it a resize).
    private var dirtyFrames: [WindowID: Bool] = [:]
    private var flushDeadline: CFTimeInterval?
    private static let ownMoveQuiet: CFTimeInterval = 0.25
    private static let trailingDelay: CFTimeInterval = 0.2
    /// Batches the notification bursts of a user drag (one read per 30 ms, not per event).
    private static let coalesceDelay: CFTimeInterval = 0.03

    /// Backoff for apps that aren't AX-ready yet (right after launch); after the table
    /// runs out Ribbon keeps trying every `slowRetryDelay` while the app is alive.
    private static let observerRetryDelays: [TimeInterval] = [0.1, 0.3, 0.6, 1.2, 2.4]
    private static let slowRetryDelay: TimeInterval = 5

    public init(ownPID: pid_t = getpid()) {
        self.ownPID = ownPID
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        // On the system-wide element this sets the global timeout for every AX element, so
        // a hung app can't block the main thread for the default ~6 s per call.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axMessagingTimeout)
        subscribeToWorkspace()
        for app in NSWorkspace.shared.runningApplications where shouldObserve(app) {
            observe(app, attempt: 0, announceExisting: false)
        }
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(center.removeObserver)
        workspaceTokens = []
        observers.values.forEach { $0.stop() }
        observers = [:]
        registry = WindowRegistry()
        ownMoveUntil = [:]
        dirtyFrames = [:]
        flushDeadline = nil
    }

    // MARK: Queries

    public func currentWindows() -> [WindowInfo] {
        var result: [WindowInfo] = []
        for observer in observers.values {
            guard let app = AppMetadata.current(pid: observer.pid) else { continue }
            for element in observer.appElement.elements(kAXWindowsAttribute) {
                guard let id = element.windowID else { continue }
                adopt(id, element: element, observer: observer)
                guard let info = WindowInfoFactory.read(id: id, element: element, app: app) else { continue }
                registry = registry.settingPhase(.announced, for: id).settingFullscreen(info.isFullscreen, for: id)
                result.append(info)
            }
        }
        return result
    }

    public func windowInfo(_ id: WindowID) -> WindowInfo? {
        guard let element = registry.element(for: id), let pid = registry.pid(of: id),
              let app = AppMetadata.current(pid: pid) else { return nil }
        return WindowInfoFactory.read(id: id, element: element, app: app)
    }

    public func focusedWindow() -> WindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appElement = observers[pid]?.appElement ?? AXUIElementCreateApplication(pid)
        return appElement.element(kAXFocusedWindowAttribute)?.windowID
    }

    /// Runs on the app's AX queue (behind its pending moves) so a busy app can't stall
    /// the key press that asked for it.
    public func focus(_ id: WindowID) {
        guard let element = registry.element(for: id), let pid = registry.pid(of: id) else {
            AXLog.windows.debug("focus: unknown window \(id)")
            return
        }
        let appElement = observers[pid]?.appElement ?? AXUIElementCreateApplication(pid)
        AXWorkQueues.shared.queue(for: pid).async {
            element.setBool(kAXMainAttribute, true)
            element.perform(kAXRaiseAction)
            appElement.setBool(kAXFrontmostAttribute, true)
            DispatchQueue.main.async {
                if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
                    app.activate(options: [])
                }
            }
        }
    }

    public func existingWindowIDs() -> Set<WindowID> { WindowList.existingWindowIDs() }

    public func onScreenWindowIDs() -> Set<WindowID> { WindowList.onScreenWindowIDs() }

    public func frame(of id: WindowID) -> CGRect? { registry.element(for: id)?.frame() }

    // MARK: Internal accessors for the applier

    func element(for id: WindowID) -> AXUIElement? { registry.element(for: id) }

    func pid(of id: WindowID) -> pid_t? { registry.pid(of: id) }

    func appElement(for pid: pid_t) -> AXUIElement? { observers[pid]?.appElement }

    /// The applier is moving `id`: hold its frame notifications until it settles.
    func noteOwnMove(_ id: WindowID) {
        ownMoveUntil[id] = CACurrentMediaTime() + Self.ownMoveQuiet
    }

    // MARK: Apps

    private func shouldObserve(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != ownPID && !app.isTerminated
    }

    /// Starts observing `app`. `announceExisting`: emit `.windowCreated` for the windows it
    /// already has (apps launched after `start()`); otherwise they're left for
    /// `currentWindows()`.
    private func observe(_ app: NSRunningApplication, attempt: Int, announceExisting: Bool) {
        let pid = app.processIdentifier
        guard isStarted, observers[pid] == nil, !app.isTerminated else { return }
        let observer = AppObserver(app: app) { [weak self] pid, element, notification in
            self?.handle(pid: pid, element: element, notification: notification)
        }
        switch observer.start() {
        case .started:
            observers[pid] = observer
            for element in observer.appElement.elements(kAXWindowsAttribute) {
                if announceExisting {
                    scheduleCreation(of: element, observer: observer, attempt: 0)
                } else if let id = element.windowID {
                    adopt(id, element: element, observer: observer)
                }
            }
        case .retryLater(let error):
            let delays = Self.observerRetryDelays
            let delay = attempt < delays.count ? delays[attempt] : Self.slowRetryDelay
            if attempt == delays.count {
                AXLog.observer.info("pid \(pid): still not AX-ready (\(error.rawValue)); retrying every \(Self.slowRetryDelay)s")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.observe(app, attempt: attempt + 1, announceExisting: true)
            }
        case .failed(let error):
            AXLog.observer.error("pid \(pid): can't observe (\(error.rawValue))")
        }
    }

    private func forgetApp(_ pid: pid_t) {
        observers.removeValue(forKey: pid)?.stop()
        for id in registry.windows(of: pid) {
            ownMoveUntil[id] = nil
            dirtyFrames[id] = nil
        }
        registry = registry.removingAll(of: pid)
        AXWorkQueues.shared.forget(pid)
    }

    private func subscribeToWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ block: @escaping (NSRunningApplication?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                block(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
            workspaceTokens.append(token)
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app, self.shouldObserve(app) else { return }
            self.observe(app, attempt: 0, announceExisting: true)
            self.emit(.appLaunched(app.processIdentifier))
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            let pid = app.processIdentifier
            guard self.observers[pid] != nil || !self.registry.windows(of: pid).isEmpty else { return }
            self.forgetApp(pid)
            self.emit(.appTerminated(pid))
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app, app.processIdentifier != self.ownPID else { return }
            let pid = app.processIdentifier
            // Covers apps that turned `.regular` after launch, or that were never AX-ready.
            if self.observers[pid] == nil, self.shouldObserve(app) {
                self.observe(app, attempt: 0, announceExisting: true)
            }
            self.emit(.appActivated(pid))
            let appElement = self.observers[pid]?.appElement ?? AXUIElementCreateApplication(pid)
            if let window = appElement.element(kAXFocusedWindowAttribute) {
                self.windowFocused(window, pid: pid)
            }
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            if let pid = app?.processIdentifier { self?.emit(.appHidden(pid)) }
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            if let pid = app?.processIdentifier { self?.emit(.appShown(pid)) }
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.emit(.spaceChanged) }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            on(name) { [weak self] _ in self?.emit(.systemWoke) }
        }
    }

    // MARK: AX notifications

    private func handle(pid: pid_t, element: AXUIElement, notification: String) {
        switch notification {
        case kAXWindowCreatedNotification:
            if let observer = observers[pid] { scheduleCreation(of: element, observer: observer, attempt: 0) }
        case kAXFocusedWindowChangedNotification:
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            windowFocused(element, pid: pid)
        case kAXUIElementDestroyedNotification:
            guard let id = registry.id(for: element) else { return }
            let wasAnnounced = registry.phase(of: id) == .announced
            observers[pid]?.unobserve(window: element)
            registry = registry.removing(id)
            ownMoveUntil[id] = nil
            dirtyFrames[id] = nil
            if wasAnnounced { emit(.windowDestroyed(id)) }
        case kAXWindowMovedNotification:
            if let id = registry.announcedID(for: element) { frameChanged(id, resized: false) }
        case kAXWindowResizedNotification:
            if let id = registry.announcedID(for: element) { frameChanged(id, resized: true) }
        case kAXWindowMiniaturizedNotification:
            if let id = registry.announcedID(for: element) { emit(.windowMinimized(id)) }
        case kAXWindowDeminiaturizedNotification:
            if let id = registry.announcedID(for: element) { emit(.windowDeminimized(id)) }
        case kAXTitleChangedNotification:
            if let id = registry.announcedID(for: element) { emit(.windowTitleChanged(id, element.string(kAXTitleAttribute) ?? "")) }
        default:
            break
        }
    }

    // MARK: Coalesced frame notifications

    private func frameChanged(_ id: WindowID, resized: Bool) {
        dirtyFrames[id] = (dirtyFrames[id] ?? false) || resized
        let now = CACurrentMediaTime()
        let quietAt = ownMoveUntil[id].map { $0 + Self.trailingDelay } ?? now
        scheduleFlush(at: max(now + Self.coalesceDelay, quietAt))
    }

    private func scheduleFlush(at deadline: CFTimeInterval) {
        if let pending = flushDeadline, pending <= deadline { return }
        flushDeadline = deadline
        let delay = max(0, deadline - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushFrames(scheduledFor: deadline)
        }
    }

    /// Reads each dirty window's frame once and reports it; windows Ribbon is still moving
    /// wait for the next flush.
    private func flushFrames(scheduledFor deadline: CFTimeInterval) {
        guard flushDeadline == deadline else { return }
        flushDeadline = nil
        let now = CACurrentMediaTime()
        var later: CFTimeInterval?
        for (id, resized) in dirtyFrames {
            if let until = ownMoveUntil[id], now < until + Self.trailingDelay - 0.001 {
                later = min(later ?? .infinity, until + Self.trailingDelay)
                continue
            }
            dirtyFrames[id] = nil
            ownMoveUntil[id] = nil
            guard registry.phase(of: id) == .announced, let element = registry.element(for: id) else { continue }
            let attributes = WindowFrameAttributes.read(from: element, includingFullscreen: resized)
            if let frame = attributes.frame {
                emit(resized ? .windowResized(id, frame) : .windowMoved(id, frame))
            }
            if let fullscreen = attributes.isFullscreen {
                if fullscreen != registry.isFullscreen(id) {
                    registry = registry.settingFullscreen(fullscreen, for: id)
                    emit(.windowFullscreenChanged(id, fullscreen))
                }
            }
        }
        if let later { scheduleFlush(at: later) }
    }

    private func windowFocused(_ element: AXUIElement, pid: pid_t) {
        guard let id = element.windowID else { return }
        switch registry.phase(of: id) {
        case .announced:
            emit(.windowFocused(id))
        case .pending:
            registry = registry.requestingFocusAfterCreation(id)
        case nil:
            guard let observer = observers[pid] else { return }
            scheduleCreation(of: element, observer: observer, attempt: 0)
            registry = registry.requestingFocusAfterCreation(id)
        }
    }

    // MARK: Window creation

    /// Registers + observes a window without announcing it.
    private func adopt(_ id: WindowID, element: AXUIElement, observer: AppObserver) {
        if registry.element(for: id).map({ !CFEqual($0, element) }) ?? true {
            registry = registry.registering(id, element: element, pid: observer.pid)
        }
        observer.observe(window: element)
    }

    /// Emits `.windowCreated` once the window's attributes have settled (see `CreationPolicy`).
    private func scheduleCreation(of element: AXUIElement, observer: AppObserver, attempt: Int) {
        guard let id = element.windowID else { return }
        if attempt == 0 {
            guard registry.phase(of: id) == nil else { return }
            adopt(id, element: element, observer: observer)
            registry = registry.settingPhase(.pending, for: id)
        }
        let delay = attempt == 0 ? CreationPolicy.settleDelay : CreationPolicy.retryDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak observer] in
            guard let self, let observer, self.registry.phase(of: id) == .pending else { return }
            self.finishCreation(of: id, element: element, observer: observer, attempt: attempt)
        }
    }

    private func finishCreation(of id: WindowID, element: AXUIElement, observer: AppObserver, attempt: Int) {
        let attributes = WindowAttributes.read(from: element)
        switch CreationPolicy.step(for: attributes, attempt: attempt) {
        case .retry:
            scheduleCreation(of: element, observer: observer, attempt: attempt + 1)
        case .giveUp:
            registry = registry.settingPhase(nil, for: id)
        case .emit:
            guard let attributes, let app = AppMetadata.current(pid: observer.pid),
                  let info = WindowInfoFactory.make(id: id, attributes: attributes, app: app) else {
                registry = registry.settingPhase(nil, for: id)
                return
            }
            let focusAfter = registry.focusAfterCreation.contains(id)
            registry = registry.settingPhase(.announced, for: id).settingFullscreen(info.isFullscreen, for: id)
            emit(.windowCreated(info))
            if focusAfter { emit(.windowFocused(id)) }
        }
    }

    private func emit(_ event: WindowEvent) {
        eventHandler?(event)
    }
}
