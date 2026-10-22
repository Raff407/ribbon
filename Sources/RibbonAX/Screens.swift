import AppKit
import RibbonCore

/// Geometry of the primary display, the origin of AX space.
enum PrimaryScreen {
    /// Height of the primary display's full frame (`NSScreen.screens[0]`, never
    /// `NSScreen.main`, which follows the key window). Falls back to the CoreGraphics main
    /// display (also the menu-bar display) when AppKit reports no screens.
    static var height: CGFloat {
        if let primary = NSScreen.screens.first {
            return primary.frame.height
        }
        return CGDisplayBounds(CGMainDisplayID()).height
    }
}

/// Pure conversions from AppKit screen data to `DisplayInfo`.
enum DisplayGeometry {
    /// Builds a `DisplayInfo` from Cocoa-space frames, converting them to AX space.
    static func displayInfo(
        id: UInt32, uuid: String, name: String,
        cocoaFrame: CGRect, cocoaVisibleFrame: CGRect,
        primaryHeight: CGFloat, isMain: Bool
    ) -> DisplayInfo {
        DisplayInfo(
            id: id, uuid: uuid, name: name,
            frame: CoordinateSpace.flip(cocoaFrame, primaryHeight: primaryHeight),
            visibleFrame: CoordinateSpace.flip(cocoaVisibleFrame, primaryHeight: primaryHeight),
            isMain: isMain
        )
    }

    /// Left to right by `frame.minX`, ties broken by `frame.minY` (then id, for stability).
    static func sorted(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.sorted { a, b in
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
            return a.id < b.id
        }
    }

    /// Stable UUID string for a display; a synthetic id when CoreGraphics has none.
    static func uuidString(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(kCFAllocatorDefault, uuid)
        else {
            return "display-\(displayID)"
        }
        return string as String
    }

    /// The `NSScreenNumber` (CGDirectDisplayID) of a screen.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

/// `ScreenProviding` over `NSScreen`. Screen-parameter changes are debounced so a display
/// reconfiguration (which posts several notifications) triggers one relayout.
public final class SystemScreenProvider: ScreenProviding {
    public var changeHandler: (() -> Void)?

    static let debounceInterval: TimeInterval = 0.3

    private var screenObserver: NSObjectProtocol?
    private var pendingChange: DispatchWorkItem?

    public init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleChange()
        }
    }

    deinit {
        pendingChange?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    public func displays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            AXLog.screens.error("NSScreen.screens is empty")
            return []
        }
        let primaryHeight = primary.frame.height
        let infos = screens.enumerated().compactMap { index, screen -> DisplayInfo? in
            guard let id = DisplayGeometry.displayID(of: screen) else {
                AXLog.screens.error("Screen \(index) has no NSScreenNumber; skipped")
                return nil
            }
            return DisplayGeometry.displayInfo(
                id: id, uuid: DisplayGeometry.uuidString(for: id), name: screen.localizedName,
                cocoaFrame: screen.frame, cocoaVisibleFrame: screen.visibleFrame,
                primaryHeight: primaryHeight, isMain: index == 0
            )
        }
        return DisplayGeometry.sorted(infos)
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingChange = nil
            self?.changeHandler?()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}
