import AppKit
import RibbonCore

/// The strip indicator: a frosted HUD pill at the bottom centre of a display showing
/// one app-icon tile per column.
///
/// * Non-persistent: click-through; fades out (0.25 s) after `duration`. A new `show`
///   resets the timer.
/// * Persistent: clickable (tile click / drag-to-reorder) and stays up until `hide()`.
final class StripIndicatorWindow: OverlayPanel {
    static let cornerRadius: CGFloat = 14
    /// Distance from the bottom of the display's visible frame.
    static let bottomInset: CGFloat = 24
    /// Horizontal margin kept free on each side of the display.
    static let sideMargin: CGFloat = 40
    static let fadeOutDuration: TimeInterval = 0.25
    static let fadeInDuration: TimeInterval = 0.12

    let indicatorView = StripIndicatorView()
    private let effectView = NSVisualEffectView()
    private var hideTimer: Timer?
    /// Bumped on every show/hide so a stale fade completion never hides a newer show.
    private var generation = 0

    init() {
        super.init(level: .floating)
        appearance = NSAppearance(named: .darkAqua)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = .roundedMask(radius: Self.cornerRadius)
        effectView.autoresizingMask = [.width, .height]
        indicatorView.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(effectView)
        container.addSubview(indicatorView)
        contentView = container
        alphaValue = 0
    }

    deinit {
        hideTimer?.invalidate()
    }

    /// Shows or updates the indicator on the display whose visible frame (AX space) is
    /// `visibleFrameAX`.
    func show(_ model: IndicatorModel, icons: [NSImage], visibleFrameAX: CGRect,
              persistent: Bool, duration: TimeInterval) {
        generation += 1
        hideTimer?.invalidate()
        hideTimer = nil

        let visible = ScreenGeometry.cocoaRect(fromAX: visibleFrameAX)
        let layout = StripIndicatorLayout(tileCount: model.tiles.count,
                                          maxWidth: visible.width - Self.sideMargin * 2)
        let size = layout.size
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: (visible.minY + Self.bottomInset).rounded())
        setFrame(CGRect(origin: origin, size: size), display: false)
        effectView.frame = CGRect(origin: .zero, size: size)
        indicatorView.frame = CGRect(origin: .zero, size: size)
        indicatorView.content = .init(model: model, icons: icons, layout: layout)

        ignoresMouseEvents = !persistent
        present()
        animateAlpha(to: 1, duration: Self.fadeInDuration)
        if !persistent { scheduleHide(after: duration) }
    }

    /// Fades out and orders out (or orders out at once when `animated` is false).
    func hide(animated: Bool) {
        generation += 1
        hideTimer?.invalidate()
        hideTimer = nil
        ignoresMouseEvents = true
        guard isVisible else { return }
        guard animated else {
            alphaValue = 0
            dismiss()
            return
        }
        let token = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == token else { return }
            self.dismiss()
        })
    }

    private func scheduleHide(after duration: TimeInterval) {
        let timer = Timer(timeInterval: max(0.1, duration), repeats: false) { [weak self] _ in
            self?.hide(animated: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func animateAlpha(to value: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            self.animator().alphaValue = value
        }
    }
}
