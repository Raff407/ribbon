import AppKit
import RibbonCore

/// A clickable bar above a tabbed column: equal-width tabs (icon + truncating title),
/// the active one highlighted. Clicking a tab calls `onTabClick` with its window.
final class TabBarWindow: OverlayPanel {
    static let cornerRadius: CGFloat = 7

    let barView = TabBarView()
    private let effectView = NSVisualEffectView()

    init() {
        super.init(level: .floating, clickThrough: false)
        effectView.material = .headerView
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = .roundedMask(radius: Self.cornerRadius)
        effectView.autoresizingMask = [.width, .height]
        barView.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(effectView)
        container.addSubview(barView)
        contentView = container
    }

    /// Shows the bar for `model` (frame in AX space).
    func show(_ model: TabBarModel, icons: [NSImage]) {
        let target = ScreenGeometry.cocoaRect(fromAX: model.frame).integral
        guard target.width > 1, target.height > 1 else { dismiss(); return }
        if frame != target { setFrame(target, display: false) }
        effectView.frame = CGRect(origin: .zero, size: target.size)
        barView.frame = CGRect(origin: .zero, size: target.size)
        barView.content = .init(model: model, icons: icons)
        present()
    }
}

final class TabBarView: NSView {
    struct Content {
        var model: TabBarModel
        var icons: [NSImage]
    }

    static let inset: CGFloat = 3
    static let spacing: CGFloat = 2
    static let iconSize: CGFloat = 16
    static let iconOnlyWidth: CGFloat = 44

    var onTabClick: ((WindowID) -> Void)?
    var content = Content(model: TabBarModel(frame: .zero, tabs: [], activeIndex: 0), icons: []) {
        didSet {
            if Self.needsRedraw(content, after: oldValue) { needsDisplay = true }
        }
    }

    /// Moving a tab bar doesn't change its local drawing, so a viewport scroll doesn't
    /// redraw every title and icon; tabs, the active tab, size or icons changing does.
    static func needsRedraw(_ content: Content, after old: Content) -> Bool {
        content.model.tabs != old.model.tabs
            || content.model.activeIndex != old.model.activeIndex
            || content.model.frame.size != old.model.frame.size
            || content.icons != old.icons
    }

    private var pressedIndex: Int?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Equal-width tab rects across the bar.
    func tabRects() -> [CGRect] {
        let count = content.model.tabs.count
        guard count > 0 else { return [] }
        let area = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let width = (area.width - Self.spacing * CGFloat(count - 1)) / CGFloat(count)
        guard width > 0 else { return [] }
        return (0..<count).map { i in
            CGRect(x: area.minX + CGFloat(i) * (width + Self.spacing), y: area.minY,
                   width: width, height: area.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rects = tabRects()
        for (index, rect) in rects.enumerated() {
            let isActive = index == content.model.activeIndex
            if isActive { drawActiveBackground(rect) }
            if index > 0, !isActive, index - 1 != content.model.activeIndex { drawSeparator(before: rect) }
            drawTab(index, in: rect, isActive: isActive)
        }
    }

    private func drawActiveBackground(_ rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawSeparator(before rect: CGRect) {
        let x = rect.minX - Self.spacing / 2
        NSColor.separatorColor.setFill()
        CGRect(x: x - 0.5, y: rect.minY + 5, width: 1, height: max(0, rect.height - 10)).fill()
    }

    private func drawTab(_ index: Int, in rect: CGRect, isActive: Bool) {
        let tab = content.model.tabs[index]
        let icon = content.icons.indices.contains(index) ? content.icons[index] : nil
        let iconSide = min(Self.iconSize, rect.height - 4)
        if rect.width < Self.iconOnlyWidth {
            let iconRect = CGRect(x: rect.midX - iconSide / 2, y: rect.midY - iconSide / 2,
                                  width: iconSide, height: iconSide)
            icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: isActive ? 1 : 0.7)
            return
        }
        let iconRect = CGRect(x: rect.minX + 8, y: rect.midY - iconSide / 2, width: iconSide, height: iconSide)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: isActive ? 1 : 0.7)
        let textX = iconRect.maxX + 6
        let title = tab.title.isEmpty ? tab.appName : tab.title
        drawTitle(title, in: CGRect(x: textX, y: rect.minY, width: rect.maxX - 8 - textX, height: rect.height),
                  isActive: isActive)
    }

    private func drawTitle(_ title: String, in rect: CGRect, isActive: Bool) {
        guard rect.width > 4 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let lineHeight = ceil(font.ascender - font.descender)
        let textRect = CGRect(x: rect.minX, y: rect.midY - lineHeight / 2, width: rect.width, height: lineHeight)
        (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: attributes)
    }

    // MARK: - Clicks

    private func tabIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return tabRects().firstIndex { $0.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        pressedIndex = tabIndex(at: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedIndex = nil }
        guard let pressed = pressedIndex, tabIndex(at: event) == pressed,
              content.model.tabs.indices.contains(pressed) else { return }
        onTabClick?(content.model.tabs[pressed].window)
    }
}
