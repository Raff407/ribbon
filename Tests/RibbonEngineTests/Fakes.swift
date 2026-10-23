import CoreGraphics
import Foundation
import RibbonCore
@testable import RibbonEngine

final class FakeWindowSource: WindowSource {
    var eventHandler: ((WindowEvent) -> Void)?
    var windows: [WindowID: WindowInfo] = [:]
    var focused: WindowID?
    /// nil = every window in `windows`.
    var existingOverride: Set<WindowID>?
    var onScreenOverride: Set<WindowID>?
    /// Windows AX can't see right now (other Space) but that still exist.
    var hiddenFromAX: Set<WindowID> = []
    /// Individual AX reads can fail even while cached/window-server data remains.
    var unavailableInfo: Set<WindowID> = []
    private(set) var focusCalls: [WindowID] = []
    private(set) var started = false
    private(set) var scanCount = 0

    func start() { started = true }
    func stop() { started = false }
    func currentWindows() -> [WindowInfo] {
        scanCount += 1
        return windows.values.filter { !hiddenFromAX.contains($0.id) }.sorted { $0.id < $1.id }
    }
    func windowInfo(_ id: WindowID) -> WindowInfo? { unavailableInfo.contains(id) ? nil : windows[id] }
    func focusedWindow() -> WindowID? { focused }
    func focus(_ id: WindowID) {
        focusCalls.append(id)
        focused = id
    }
    func existingWindowIDs() -> Set<WindowID> { existingOverride ?? Set(windows.keys) }
    func onScreenWindowIDs() -> Set<WindowID> { onScreenOverride ?? Set(windows.keys) }
    func frame(of id: WindowID) -> CGRect? { windows[id]?.frame }

    func emit(_ event: WindowEvent) { eventHandler?(event) }

    func add(_ info: WindowInfo) { windows[info.id] = info }
}

final class FakeApplier: FrameApplying {
    var recordsApplications = true
    private(set) var applied: [[WindowID: FrameTransition]] = []
    private(set) var animatedFlags: [Bool] = []
    var expected: [WindowID: CGRect] = [:]
    var animating = false
    var framesAfterCancelling: [WindowID: CGRect] = [:]
    private(set) var cancelCount = 0

    func apply(_ transitions: [WindowID: FrameTransition], animation: AnimationSpec?) {
        if recordsApplications {
            applied.append(transitions)
            animatedFlags.append(animation != nil)
        }
        for (id, t) in transitions { expected[id] = t.settledFrame }
    }
    func cancelAll() {
        cancelCount += 1
        expected.merge(framesAfterCancelling) { _, stopped in stopped }
        framesAfterCancelling = [:]
        animating = false
    }
    var isAnimating: Bool { animating }
    func expectedFrame(of id: WindowID) -> CGRect? { expected[id] }
    func forget(_ id: WindowID) { expected[id] = nil }
    private(set) var drainCount = 0
    func finishPendingWrites() { drainCount += 1 }

    var lastTransitions: [WindowID: FrameTransition] { applied.last ?? [:] }
}

final class FakeScreens: ScreenProviding {
    var changeHandler: (() -> Void)?
    var list: [DisplayInfo]
    init(_ list: [DisplayInfo]) { self.list = list }
    func displays() -> [DisplayInfo] { list }
}

final class FakeSpaces: SpaceProviding {
    var changeHandler: (() -> Void)?
    var current: [String: UInt64] = [:]
    var windowSpaces: [WindowID: UInt64] = [:]
    func currentSpace(forDisplayUUID uuid: String) -> UInt64 { current[uuid] ?? 0 }
    func spaces(for windows: [WindowID]) -> [WindowID: UInt64] { windowSpaces.filter { windows.contains($0.key) } }
}

final class FakeHotkeys: HotkeyRegistering {
    var commandHandler: ((Command) -> Void)?
    var modifierHoldHandler: ((Bool) -> Void)?
    private(set) var registered: [KeyBinding] = []
    var failing: Set<KeyCombo> = []
    private(set) var suspended = false
    func register(_ bindings: [KeyBinding]) -> [KeyBinding] {
        registered = bindings
        return bindings.filter { failing.contains($0.combo) }
    }
    func unregisterAll() { registered = [] }
    func setSuspended(_ suspended: Bool) { self.suspended = suspended }
}

final class FakeGestures: GestureSource {
    var handler: ((GestureEvent) -> Void)?
    private(set) var configured: TrackpadSettings?
    private(set) var running = false
    func configure(_ settings: TrackpadSettings) { configured = settings }
    func start() { running = true }
    func stop() { running = false }
}

final class FakeOverlays: OverlayPresenting {
    var tileClickHandler: ((Int) -> Void)?
    var tileReorderHandler: ((Int, Int) -> Void)?
    var tabClickHandler: ((WindowID) -> Void)?
    private(set) var indicatorShows: [(model: IndicatorModel, persistent: Bool)] = []
    private(set) var focusFrames: [CGRect?] = []
    private(set) var tabBars: [TabBarModel] = []
    private(set) var hideAllCount = 0
    private(set) var appearance: AppearanceSettings?
    func configure(_ appearance: AppearanceSettings) { self.appearance = appearance }
    func showIndicator(_ model: IndicatorModel, on display: DisplayInfo, persistent: Bool) {
        indicatorShows.append((model, persistent))
    }
    func hideIndicator() {}
    func updateFocus(frame: CGRect?, display: DisplayInfo?) { focusFrames.append(frame) }
    func updateTabBars(_ bars: [TabBarModel]) { tabBars = bars }
    func hideAll() { hideAllCount += 1 }
}

final class FakeInput: InputStateProviding {
    var mouse = CGPoint(x: 500, y: 400)
    var leftDown = false
    private(set) var warps: [CGPoint] = []
    var mouseMovedHandler: ((CGPoint) -> Void)?
    var mouseUpHandler: (() -> Void)?
    private(set) var tracking = false
    func mouseLocation() -> CGPoint { mouse }
    var isLeftMouseDown: Bool { leftDown }
    func warpMouse(to point: CGPoint) { warps.append(point) }
    func setMouseTracking(_ enabled: Bool) { tracking = enabled }
}

/// A scheduler whose clock only moves when the test says so.
final class ManualScheduler: Scheduler {
    private final class Task: Cancellable {
        let due: TimeInterval
        let order: Int
        let block: () -> Void
        var cancelled = false
        init(due: TimeInterval, order: Int, block: @escaping () -> Void) {
            self.due = due
            self.order = order
            self.block = block
        }
        func cancel() { cancelled = true }
    }

    private(set) var time: TimeInterval = 100
    private var tasks: [Task] = []
    private var counter = 0

    @discardableResult
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        counter += 1
        let task = Task(due: time + max(0, delay), order: counter, block: block)
        tasks.append(task)
        return task
    }

    func now() -> TimeInterval { time }

    /// Advances the clock, running every task that falls due (including ones scheduled
    /// by tasks that ran), in due order.
    func advance(by delta: TimeInterval) {
        let end = time + delta
        while let next = tasks.filter({ !$0.cancelled && $0.due <= end }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            tasks.removeAll { $0 === next }
            time = max(time, next.due)
            next.block()
        }
        tasks.removeAll { $0.cancelled }
        time = end
    }
}

final class InMemorySessionStore: SessionStoring {
    var snapshot: SessionSnapshot?
    private(set) var saveCount = 0
    func load() -> SessionSnapshot? { snapshot }
    func save(_ snapshot: SessionSnapshot) {
        self.snapshot = snapshot
        saveCount += 1
    }
}

/// Everything a test needs, wired together.
final class Harness {
    let windows = FakeWindowSource()
    let applier = FakeApplier()
    let screens: FakeScreens
    let spaces = FakeSpaces()
    let hotkeys = FakeHotkeys()
    let gestures = FakeGestures()
    let overlays = FakeOverlays()
    let input = FakeInput()
    let scheduler = ManualScheduler()
    let store = InMemorySessionStore()
    let manager: WindowManager

    static let mainDisplay = DisplayInfo(id: 1, uuid: "MAIN", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                         visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775), isMain: true)
    static let rightDisplay = DisplayInfo(id: 2, uuid: "RIGHT", name: "External", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                                          visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800), isMain: false)

    static var testSettings: RibbonSettings {
        var s = RibbonSettings.defaults
        s.layout.gap = 10
        s.layout.outerGap = 0
        s.animation.enabled = false
        s.behavior.reconcileInterval = 0
        s.behavior.restoreSession = false
        return s
    }

    init(displays: [DisplayInfo] = [Harness.mainDisplay], settings: RibbonSettings = Harness.testSettings) {
        screens = FakeScreens(displays)
        let services = EngineServices(windows: windows, screens: screens, spaces: spaces, applier: applier, hotkeys: hotkeys,
                                      gestures: gestures, overlays: overlays, input: input, scheduler: scheduler, sessionStore: store)
        manager = WindowManager(services: services, settings: settings, ownBundleID: "com.raff.ribbon")
    }

    var key: StripKey { StripKey(displayUUID: "MAIN", spaceID: spaces.current["MAIN"] ?? 0) }
    var strip: Strip { manager.world.strip(key) }
    var order: [[WindowID]] { strip.columns.map(\.windows) }

    /// Starts the manager with windows laid out left to right (ids double as x order).
    @discardableResult
    func start(_ ids: [WindowID] = [], focused: WindowID? = nil) -> Harness {
        for (i, id) in ids.enumerated() { windows.add(win(id, x: CGFloat(i) * 100)) }
        windows.focused = focused
        manager.start()
        scheduler.advance(by: 1)
        return self
    }

    func win(_ id: WindowID, x: CGFloat = 0, y: CGFloat = 100, pid: ProcessID = 10, bundle: String = "com.test.app",
             width: CGFloat = 400, height: CGFloat = 300) -> WindowInfo {
        WindowInfo(id: id, pid: pid, bundleID: bundle, appName: "App\(pid)", title: "W\(id)",
                   frame: CGRect(x: x, y: y, width: width, height: height))
    }

    func settle() { scheduler.advance(by: 1) }
}
