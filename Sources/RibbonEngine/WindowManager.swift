import CoreGraphics
import Foundation
import RibbonCore

/// The window-manager brain: keeps the `World` (strips + floating windows) in sync with
/// the windows on screen, turns commands/gestures/events into new strips with RibbonCore's
/// pure operations, and pushes the resulting frames to the applier. Main thread only.
public final class WindowManager {
    /// Called on main whenever the enabled flag or managed-window set changes.
    public var stateChangeHandler: (() -> Void)?
    /// Called when the user invokes `.openSettings`.
    public var openSettingsHandler: (() -> Void)?

    public private(set) var isEnabled = false
    /// Bindings that failed to register on the last settings update.
    public private(set) var failedBindings: [KeyBinding] = []
    public internal(set) var world = World()

    public var managedWindowCount: Int { world.allTiledWindows.count + world.floating.count }

    struct RestoreHint: Equatable {
        var key: StripKey
        var column: Int
        var wasFloating: Bool
        /// Parking order: restoring newest-first rebuilds the original column order.
        var sequence: Int
    }

    let services: EngineServices
    let ownBundleID: String?
    var settings: RibbonSettings

    var infos: [WindowID: WindowInfo] = [:]
    var restoreHints: [WindowID: RestoreHint] = [:]
    /// Native macOS tab groups: every member maps to the whole group. Only one member of a
    /// group is on the strip at a time (the active tab).
    var tabGroups: [WindowID: Set<WindowID>] = [:]
    /// Windows whose native-tab status is being checked (not tiled yet).
    var pendingTabChecks: Set<WindowID> = []
    var displays: [DisplayInfo] = []
    public internal(set) var isStarted = false
    /// The system's focused window as far as Ribbon knows.
    var focusedWindowID: WindowID?
    /// A window Ribbon just focused; focus events for other windows are stale until `until`.
    var pendingFocus: (window: WindowID, until: TimeInterval)?
    /// A window focused by focus-follows-mouse (must not scroll the strip).
    var suppressRevealFor: WindowID?
    var lastLayoutTime: [WindowID: TimeInterval] = [:]
    var widthAdoptions: [WindowID: TimeInterval] = [:]
    var refusedSizeAdoptions: [WindowID: [TimeInterval]] = [:]
    var draggedWindow: WindowID?
    var gestureKey: StripKey?
    var modifierHeld = false
    var indicatorShownPersistent = false
    var debounces: [String: Cancellable] = [:]
    var reconcileTimer: Cancellable?
    /// Window-server window set at the last full scan: periodic sweeps skip the expensive
    /// Accessibility scan while it hasn't changed.
    var lastReconcileWindowSet: Set<WindowID>?
    /// What the overlays last showed, so unchanged updates aren't re-sent every frame.
    var lastFocusOverlay: (frame: CGRect?, display: String?)?
    var lastTabBars: [TabBarModel]?
    var lastIndicator: (model: IndicatorModel, persistent: Bool, at: TimeInterval)?
    var parkSequence = 0

    static let pendingFocusWindow: TimeInterval = 0.25
    static let ownMoveWindow: TimeInterval = 0.35
    static let ownMoveTolerance: CGFloat = 4
    static let widthAdoptionInterval: TimeInterval = 2
    /// Refused sizes adopted per window within `widthAdoptionInterval`.
    static let maxRefusedSizeAdoptions = 3
    static let cascadeStep: CGFloat = 30

    public init(services: EngineServices, settings: RibbonSettings, ownBundleID: String?) {
        self.services = services
        self.settings = settings
        self.ownBundleID = ownBundleID
    }

    // MARK: Lifecycle

    /// Begins managing windows (call once permission is granted). Idempotent.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        isEnabled = true
        wireHandlers()
        failedBindings = services.hotkeys.register(settings.bindings)
        services.gestures.configure(settings.trackpad)
        services.gestures.start()
        services.overlays.configure(settings.appearance)
        services.input.setMouseTracking(true)
        services.windows.start()
        initialScan()
        scheduleReconcileTimer()
        stateChangeHandler?()
    }

    /// Stops managing: un-parks every hidden window onto its display, saves the session,
    /// unregisters everything. Safe to call twice.
    public func stop() {
        guard isStarted else { return }
        services.applier.cancelAll()
        if isEnabled { unparkAll() }
        services.applier.finishPendingWrites()
        saveNow()
        services.overlays.hideAll()
        resetOverlayCache()
        services.hotkeys.unregisterAll()
        services.gestures.stop()
        services.input.setMouseTracking(false)
        services.windows.stop()
        cancelTimers()
        isEnabled = false
        isStarted = false
        stateChangeHandler?()
    }

    public func setEnabled(_ enabled: Bool) {
        guard isStarted, enabled != isEnabled else { return }
        if enabled {
            isEnabled = true
            failedBindings = services.hotkeys.register(settings.bindings)
            services.gestures.start()
            refreshDisplays()
            reconcile(relayoutIfChanged: false)
            revealAllActiveStrips()
            relayout(animated: false, force: true)
            scheduleReconcileTimer()
        } else {
            services.applier.cancelAll()
            unparkAll()
            saveNow()
            services.overlays.hideAll()
            resetOverlayCache()
            services.hotkeys.register(settings.bindings.filter { $0.command == .toggleEnabled })
            services.gestures.stop()
            cancelTimers()
            isEnabled = false
        }
        stateChangeHandler?()
    }

    public func updateSettings(_ newSettings: RibbonSettings) {
        let old = settings
        settings = newSettings
        if old.bindings != newSettings.bindings && isStarted {
            failedBindings = isEnabled
                ? services.hotkeys.register(newSettings.bindings)
                : services.hotkeys.register(newSettings.bindings.filter { $0.command == .toggleEnabled })
        }
        services.gestures.configure(newSettings.trackpad)
        services.overlays.configure(newSettings.appearance)
        guard isStarted, isEnabled else {
            stateChangeHandler?()
            return
        }
        if old.disabledDisplays != newSettings.disabledDisplays { releaseDisabledDisplays() }
        let classificationChanged = old.rules != newSettings.rules
            || old.behavior.floatDialogs != newSettings.behavior.floatDialogs
            || old.behavior.floatFixedSizeWindows != newSettings.behavior.floatFixedSizeWindows
        if classificationChanged { reclassifyManagedWindows() }
        if old.behavior.reconcileInterval != newSettings.behavior.reconcileInterval { scheduleReconcileTimer() }
        // Windows that were ignored or on a disabled display may be manageable now.
        if classificationChanged || old.disabledDisplays != newSettings.disabledDisplays { reconcile(relayoutIfChanged: false) }
        revealAllActiveStrips()
        relayout(animated: true, force: true)
        stateChangeHandler?()
    }

    public func relayout() {
        guard isEnabled else { return }
        relayout(animated: true, force: true)
    }

    public func gatherAllWindows() {
        if isEnabled {
            refreshDisplays()
            reconcile(relayoutIfChanged: false)
            revealAllActiveStrips()
            relayout(animated: false, force: true)
        } else {
            unparkAll()
        }
    }

    // MARK: Wiring

    private func wireHandlers() {
        services.windows.eventHandler = { [weak self] in self?.handle($0) }
        services.screens.changeHandler = { [weak self] in self?.screensChanged() }
        services.spaces.changeHandler = { [weak self] in self?.debounce("space", 0.2) { self?.spaceChanged() } }
        services.hotkeys.commandHandler = { [weak self] in self?.perform($0) }
        services.hotkeys.modifierHoldHandler = { [weak self] in self?.modifierHoldChanged($0) }
        services.gestures.handler = { [weak self] in self?.handleGesture($0) }
        services.overlays.tileClickHandler = { [weak self] in self?.indicatorTileClicked($0) }
        services.overlays.tileReorderHandler = { [weak self] in self?.indicatorTileMoved(from: $0, to: $1) }
        services.overlays.tabClickHandler = { [weak self] in self?.tabClicked($0) }
        services.input.mouseMovedHandler = { [weak self] in self?.mouseMoved(to: $0) }
        services.input.mouseUpHandler = { [weak self] in self?.mouseUp() }
    }

    // MARK: Timers

    func debounce(_ name: String, _ delay: TimeInterval, _ block: @escaping () -> Void) {
        debounces[name]?.cancel()
        debounces[name] = services.scheduler.schedule(after: delay) { [weak self] in
            self?.debounces[name] = nil
            block()
        }
    }

    func scheduleReconcileTimer() {
        reconcileTimer?.cancel()
        reconcileTimer = nil
        let interval = settings.behavior.reconcileInterval
        guard interval > 0, isEnabled else { return }
        reconcileTimer = services.scheduler.schedule(after: interval) { [weak self] in
            guard let self, self.isEnabled else { return }
            if self.draggedWindow == nil && self.gestureKey == nil {
                self.reconcile(relayoutIfChanged: true, onlyIfWindowsChanged: true)
            }
            self.scheduleReconcileTimer()
        }
    }

    func resetOverlayCache() {
        lastFocusOverlay = nil
        lastTabBars = nil
        lastIndicator = nil
    }

    private func cancelTimers() {
        reconcileTimer?.cancel()
        reconcileTimer = nil
        debounces.values.forEach { $0.cancel() }
        debounces = [:]
        pendingTabChecks.removeAll()
        pendingFocus = nil
        suppressRevealFor = nil
        draggedWindow = nil
        gestureKey = nil
        modifierHeld = false
        indicatorShownPersistent = false
    }

    // MARK: Persistence

    func scheduleSave() {
        debounce("save", 1) { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        debounces["save"]?.cancel()
        debounces["save"] = nil
        services.sessionStore.save(SessionRestorer.snapshot(of: world, windows: infos))
    }
}
