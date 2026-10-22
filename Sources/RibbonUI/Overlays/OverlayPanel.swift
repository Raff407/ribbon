import AppKit
import RibbonCore

/// Base class for every overlay window: a borderless, non-activating panel that can
/// never become key or main, has no shadow, is transparent, shows on every Space (and
/// next to full-screen apps) and is reused rather than released when hidden.
///
/// Overlays are click-through by default; subclasses that take clicks (the persistent
/// strip indicator, tab bars) turn `ignoresMouseEvents` off explicitly.
class OverlayPanel: NSPanel {
    init(level: NSWindow.Level, clickThrough: Bool = true) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // Setting isFloatingPanel resets the level to .floating, so the level goes last.
        isFloatingPanel = true
        self.level = level
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        // Ribbon is an accessory app that is almost never active: panels hide on
        // deactivation by default, which would make every overlay vanish.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = clickThrough
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel without activating Ribbon or taking focus.
    func present() {
        if !isVisible { orderFrontRegardless() }
    }

    /// Hides the panel (kept for reuse).
    func dismiss() {
        if isVisible { orderOut(nil) }
    }
}

/// AX (top-left origin, y down) ↔ Cocoa (bottom-left origin, y up) conversion using the
/// primary display — `NSScreen.screens[0]`, the one with the menu bar.
enum ScreenGeometry {
    /// Height of the primary display's full frame (0 when no screen is attached, which
    /// just leaves rects unflipped instead of crashing).
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CoordinateSpace.flip(rect, primaryHeight: primaryHeight)
    }

    /// Cocoa frames of every attached display.
    static var screenFrames: [CGRect] { NSScreen.screens.map(\.frame) }
}

extension NSImage {
    /// A stretchable rounded-rect mask for `NSVisualEffectView.maskImage` (the reliable
    /// way to round a behind-window blur).
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
