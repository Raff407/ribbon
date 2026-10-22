import AppKit
import QuartzCore

/// A click-through window covering one display, black at the dim amount, with an
/// even-odd hole cut out for the focused window.
final class DimOverlayWindow: OverlayPanel {
    static let holeAnimationDuration: TimeInterval = 0.15

    private let dimView = DimOverlayView()

    init() {
        // One level below the other overlays so re-showing the dimming never covers the
        // tab bars or the strip indicator.
        super.init(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1))
        dimView.autoresizingMask = [.width, .height]
        contentView = dimView
    }

    /// Covers `screenFrame` (Cocoa) and leaves `holeCocoa` (Cocoa, global) undimmed.
    func show(screenFrame: CGRect, holeCocoa: CGRect?, amount: CGFloat, cornerRadius: CGFloat) {
        if frame != screenFrame { setFrame(screenFrame, display: false) }
        let localHole = holeCocoa.map { $0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
        dimView.update(hole: localHole, amount: amount, cornerRadius: cornerRadius)
        present()
    }
}

final class DimOverlayView: NSView {
    private let shape = CAShapeLayer()
    private var hole: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillRule = .evenOdd
        shape.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(hole newHole: CGRect?, amount: CGFloat, cornerRadius: CGFloat) {
        let animateHole = hole != nil && newHole != nil && hole != newHole
        hole = newHole
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.opacity = Float(min(max(amount, 0), 1))
        let newPath = Self.path(bounds: bounds, hole: newHole, cornerRadius: cornerRadius)
        if animateHole, let oldPath = shape.presentation()?.path ?? shape.path {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = oldPath
            animation.toValue = newPath
            animation.duration = DimOverlayWindow.holeAnimationDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(animation, forKey: "path")
        }
        shape.path = newPath
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        CATransaction.commit()
    }

    /// The whole view plus the hole; even-odd filling leaves the hole clear.
    static func path(bounds: CGRect, hole: CGRect?, cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole {
            let clipped = hole.intersection(bounds)
            if !clipped.isNull, clipped == hole {
                RoundedPath.add(hole, radius: cornerRadius, to: path)
            } else if !clipped.isNull {
                // Partly off this display: a square-cornered cut keeps the even-odd
                // fill well-formed at the display edge.
                path.addRect(clipped)
            }
        }
        return path
    }
}
