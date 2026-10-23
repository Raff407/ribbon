import CoreGraphics
import Foundation

// Platform abstractions. RibbonEngine only talks to the OS through these, so it can be
// tested with fakes. RibbonAX / RibbonInput / RibbonUI provide the real implementations.
// All callbacks are delivered on the main thread; all methods are called on the main thread.

// MARK: - Windows

/// A snapshot of one window as reported by the Accessibility API.
public struct WindowInfo: Equatable, Sendable {
    public var id: WindowID
    public var pid: ProcessID
    public var bundleID: String?
    public var appName: String
    public var title: String
    /// AX space.
    public var frame: CGRect
    /// `kAXRoleAttribute`, normally "AXWindow".
    public var role: String?
    /// `kAXSubroleAttribute`: "AXStandardWindow", "AXDialog", "AXSystemDialog",
    /// "AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown", …
    public var subrole: String?
    /// The size attribute is settable and the zoom (green) button, if present, is enabled.
    public var isResizable: Bool
    public var isMinimized: Bool
    /// In native macOS full screen.
    public var isFullscreen: Bool
    /// The owning app is hidden (⌘H).
    public var isAppHidden: Bool
    /// The owning app's activation policy is `.regular`.
    public var isRegularApp: Bool

    public init(
        id: WindowID, pid: ProcessID, bundleID: String?, appName: String, title: String,
        frame: CGRect, role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
        isResizable: Bool = true, isMinimized: Bool = false, isFullscreen: Bool = false,
        isAppHidden: Bool = false, isRegularApp: Bool = true
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.role = role
        self.subrole = subrole
        self.isResizable = isResizable
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isAppHidden = isAppHidden
        self.isRegularApp = isRegularApp
    }
}

public enum WindowEvent: Equatable, Sendable {
    case windowCreated(WindowInfo)
    case windowDestroyed(WindowID)
    /// The system focused window changed (frontmost app's focused window).
    case windowFocused(WindowID)
    /// Reported position changed (by anyone, including Ribbon itself).
    case windowMoved(WindowID, CGRect)
    case windowResized(WindowID, CGRect)
    /// The window kept a different size than Ribbon set (a minimum or fixed size); the
    /// frame is where it actually is.
    case windowRefusedSize(WindowID, CGRect)
    case windowMinimized(WindowID)
    case windowDeminimized(WindowID)
    case windowTitleChanged(WindowID, String)
    case windowFullscreenChanged(WindowID, Bool)
    case appLaunched(ProcessID)
    case appTerminated(ProcessID)
    case appHidden(ProcessID)
    case appShown(ProcessID)
    case appActivated(ProcessID)
    /// The active Space changed on some display.
    case spaceChanged
    /// The machine woke from sleep / the session became active again / screens woke.
    case systemWoke
}

public protocol WindowSource: AnyObject {
    var eventHandler: ((WindowEvent) -> Void)? { get set }
    /// Starts observing every running regular app (and apps launched later).
    func start()
    func stop()
    /// Every window of every observed app that AX can see right now (normally only the
    /// current Space(s)). Includes dialogs/minimized windows; filtering is the engine's job.
    func currentWindows() -> [WindowInfo]
    func windowInfo(_ id: WindowID) -> WindowInfo?
    /// The focused window of the frontmost app, if Ribbon can resolve it.
    func focusedWindow() -> WindowID?
    /// Raises the window, makes it main/focused and activates its app.
    func focus(_ id: WindowID)
    /// Ids of every window the window server knows, on any Space
    /// (`CGWindowListCopyWindowInfo(.optionAll)`), used to tell "on another Space" apart
    /// from "closed".
    func existingWindowIDs() -> Set<WindowID>
    /// Ids of windows currently on screen on any display
    /// (`CGWindowListCopyWindowInfo(.optionOnScreenOnly)`, layer 0). Parked windows count
    /// as on screen; inactive native tabs and windows on other Spaces don't.
    func onScreenWindowIDs() -> Set<WindowID>
    /// Current AX frame of the window (fresh query).
    func frame(of id: WindowID) -> CGRect?
}

// MARK: - Applying frames

public struct AnimationSpec: Equatable, Sendable {
    public var spring: SpringParameters

    public init(spring: SpringParameters) {
        self.spring = spring
    }
}

public protocol FrameApplying: AnyObject {
    /// Applies the transitions. With `animation == nil` every window goes straight to its
    /// `settledFrame`. With an animation: `start` (if any) and the target size are applied
    /// instantly, the origin springs to `target.origin`, then `final` (if any) is applied.
    /// A window already animating is retargeted smoothly (velocity kept). Windows not in
    /// `transitions` keep animating towards their previous targets.
    func apply(_ transitions: [WindowID: FrameTransition], animation: AnimationSpec?)
    /// Stops every animation where it is.
    func cancelAll()
    var isAnimating: Bool { get }
    /// The last frame Ribbon set (or is animating towards) for the window — the engine
    /// compares reported moves against this to tell its own moves from the user's.
    func expectedFrame(of id: WindowID) -> CGRect?
    /// Forget a window (closed / no longer managed).
    func forget(_ id: WindowID)
    /// Blocks (briefly) until every frame change requested so far has reached its app.
    /// Called before quitting so un-parked windows really land on screen.
    func finishPendingWrites()
}

// MARK: - Displays, Spaces, mouse

public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    /// Stable across reboots/reconnects (`CGDisplayCreateUUIDFromDisplayID`).
    public var uuid: String
    public var name: String
    /// Full frame, AX space.
    public var frame: CGRect
    /// Frame minus menu bar and Dock, AX space.
    public var visibleFrame: CGRect
    /// The primary display (menu bar, AX origin).
    public var isMain: Bool

    public init(id: UInt32, uuid: String, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }
}

public protocol ScreenProviding: AnyObject {
    /// Called (debounced, on main) when displays are added/removed/rearranged or the
    /// Dock/menu bar changes the visible frames.
    var changeHandler: (() -> Void)? { get set }
    /// Displays ordered left to right by `frame.minX` (ties by minY).
    func displays() -> [DisplayInfo]
}

public protocol SpaceProviding: AnyObject {
    /// Called on main when the active Space changes on any display.
    var changeHandler: (() -> Void)? { get set }
    /// Current Space id on that display; 0 when unknown (Spaces support unavailable).
    func currentSpace(forDisplayUUID uuid: String) -> UInt64
    /// Space id of each window (windows on several Spaces report the first); missing
    /// entries mean unknown.
    func spaces(for windows: [WindowID]) -> [WindowID: UInt64]
}

public protocol InputStateProviding: AnyObject {
    /// Mouse location, AX space.
    func mouseLocation() -> CGPoint
    var isLeftMouseDown: Bool { get }
    /// Moves the cursor (mouse-follows-focus). AX space.
    func warpMouse(to point: CGPoint)
    /// Called (throttled to ~30 Hz, main thread) when the mouse moves, for
    /// focus-follows-mouse. AX space.
    var mouseMovedHandler: ((CGPoint) -> Void)? { get set }
    /// Called when the left mouse button goes up (end of a window drag).
    var mouseUpHandler: (() -> Void)? { get set }
    func setMouseTracking(_ enabled: Bool)
}

// MARK: - Input

public protocol HotkeyRegistering: AnyObject {
    var commandHandler: ((Command) -> Void)? { get set }
    /// Called with true when ⌃⌥ (the hyper-lite prefix) is pressed down and false when
    /// released — the strip indicator stays up while it's held.
    var modifierHoldHandler: ((Bool) -> Void)? { get set }
    /// Replaces all registered hotkeys. Returns the bindings that could not be
    /// registered (e.g. taken by another app).
    @discardableResult
    func register(_ bindings: [KeyBinding]) -> [KeyBinding]
    func unregisterAll()
    /// While suspended no hotkey fires (used by the shortcut recorder).
    func setSuspended(_ suspended: Bool)
}

public enum GestureEvent: Equatable, Sendable {
    case began
    /// Horizontal movement since the last event, in points of viewport movement
    /// (positive = viewport moves right, content moves left). Already scaled by
    /// sensitivity and direction settings.
    case changed(dx: Double)
    /// Gesture ended; velocity in points/second of viewport movement.
    case ended(velocity: Double)
    case cancelled
}

public protocol GestureSource: AnyObject {
    var handler: ((GestureEvent) -> Void)? { get set }
    func configure(_ settings: TrackpadSettings)
    func start()
    func stop()
}

// MARK: - Overlays

public struct IndicatorTile: Equatable, Sendable {
    public var pid: ProcessID
    public var bundleID: String?
    public var appName: String
    public var windowCount: Int
    public var isPinned: Bool

    public init(pid: ProcessID, bundleID: String?, appName: String, windowCount: Int, isPinned: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowCount = windowCount
        self.isPinned = isPinned
    }
}

public struct IndicatorModel: Equatable, Sendable {
    public var tiles: [IndicatorTile]
    public var focusedIndex: Int?
    /// Which part of the whole strip is on screen, as fractions 0...1 of the strip width.
    public var visibleRange: ClosedRange<Double>

    public init(tiles: [IndicatorTile], focusedIndex: Int?, visibleRange: ClosedRange<Double>) {
        self.tiles = tiles
        self.focusedIndex = focusedIndex
        self.visibleRange = visibleRange
    }
}

public struct TabBarModel: Equatable, Sendable {
    public struct Tab: Equatable, Sendable {
        public var window: WindowID
        public var title: String
        public var appName: String
        public var bundleID: String?

        public init(window: WindowID, title: String, appName: String, bundleID: String?) {
            self.window = window
            self.title = title
            self.appName = appName
            self.bundleID = bundleID
        }
    }

    /// AX space: the bar spans the top of the tabbed column.
    public var frame: CGRect
    public var tabs: [Tab]
    public var activeIndex: Int

    public init(frame: CGRect, tabs: [Tab], activeIndex: Int) {
        self.frame = frame
        self.tabs = tabs
        self.activeIndex = activeIndex
    }
}

public protocol OverlayPresenting: AnyObject {
    /// User clicked tile `index` (column index) in the strip indicator.
    var tileClickHandler: ((Int) -> Void)? { get set }
    /// User dragged tile `from` to position `to`.
    var tileReorderHandler: ((Int, Int) -> Void)? { get set }
    /// User clicked a tab in a tab bar.
    var tabClickHandler: ((WindowID) -> Void)? { get set }
    func configure(_ appearance: AppearanceSettings)
    /// Shows/updates the strip indicator on a display. `persistent` keeps it up (and
    /// clickable) until `hideIndicator()`; otherwise it fades after
    /// `appearance.indicatorDuration`.
    func showIndicator(_ model: IndicatorModel, on display: DisplayInfo, persistent: Bool)
    func hideIndicator()
    /// Focus border / dimming around the focused tiled window (nil hides both). AX space.
    func updateFocus(frame: CGRect?, display: DisplayInfo?)
    /// Tab bars for every visible tabbed column (empty hides all).
    func updateTabBars(_ bars: [TabBarModel])
    func hideAll()
}

// MARK: - Time & persistence

public protocol Cancellable: AnyObject {
    func cancel()
}

public protocol Scheduler: AnyObject {
    /// Runs `block` on the main thread after `delay` seconds.
    @discardableResult
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> Cancellable
    /// Monotonic seconds.
    func now() -> TimeInterval
}

public protocol SessionStoring: AnyObject {
    func load() -> SessionSnapshot?
    func save(_ snapshot: SessionSnapshot)
}
