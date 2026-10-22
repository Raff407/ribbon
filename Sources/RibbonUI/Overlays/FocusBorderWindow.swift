import AppKit
import QuartzCore

/// Stroke style of the focus border.
struct FocusBorderStyle: Equatable {
    var width: CGFloat
    var color: NSColor
    var cornerRadius: CGFloat

    static let fallbackColor = NSColor.controlAccentColor
}

/// A click-through window around the focused window, outset by half the border width,
/// drawing a rounded-rect stroke centred on the window's edge. Frame changes animate.
final class FocusBorderWindow: OverlayPanel {
    static let animationDuration: TimeInterval = 0.15

    private let borderView = FocusBorderView()

    init() {
        super.init(level: .floating)
        borderView.autoresizingMask = [.width, .height]
        contentView = borderView
    }

    var style: FocusBorderStyle {
        get { borderView.style }
        set { borderView.style = newValue }
    }

    /// Positions the border around `focusedFrameCocoa` (the focused window's frame in
    /// Cocoa space). Animates when already visible.
    func show(around focusedFrameCocoa: CGRect) {
        let outset = style.width / 2
        let target = focusedFrameCocoa.insetBy(dx: -outset, dy: -outset).integral
        guard target.width > 1, target.height > 1 else { dismiss(); return }
        if isVisible, frame != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(target, display: true)
            }
        } else if !isVisible {
            setFrame(target, display: true)
        }
        orderFrontRegardless()
    }
}

/// Layer-backed view holding the stroke `CAShapeLayer`; the path follows the view size.
final class FocusBorderView: NSView {
    private let shape = CAShapeLayer()

    var style = FocusBorderStyle(width: 4, color: FocusBorderStyle.fallbackColor, cornerRadius: 10) {
        didSet { updateLayer(); updatePath() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillColor = nil
        layer?.addSublayer(shape)
        updateLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        shape.strokeColor = style.color.cgColor
        shape.lineWidth = style.width
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePath()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        shape.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func updatePath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        let rect = bounds.insetBy(dx: style.width / 2, dy: style.width / 2)
        shape.path = RoundedPath.make(rect, radius: style.cornerRadius)
        CATransaction.commit()
    }
}

/// Safe rounded-rect paths: `CGPath(roundedRect:)` traps when the radius is larger than
/// half the rect, so the radius is clamped and degenerate rects give an empty path.
enum RoundedPath {
    static func make(_ rect: CGRect, radius: CGFloat) -> CGPath {
        guard rect.width > 0, rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite else {
            return CGMutablePath()
        }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Adds a clamped rounded rect to `path`.
    static func add(_ rect: CGRect, radius: CGFloat, to path: CGMutablePath) {
        guard rect.width > 0, rect.height > 0 else { return }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
    }
}
