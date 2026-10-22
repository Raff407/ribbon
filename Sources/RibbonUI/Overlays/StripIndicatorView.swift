import AppKit
import RibbonCore

/// Draws the strip indicator's tiles and track, and (when interactive) turns clicks
/// into `onTileClick` and sideways drags into `onTileReorder`.
final class StripIndicatorView: NSView {
    struct Content {
        var model: IndicatorModel
        var icons: [NSImage]
        var layout: StripIndicatorLayout
    }

    private struct DragState {
        let from: Int
        let startX: CGFloat
        var currentX: CGFloat
        var isDragging: Bool
    }

    /// Minimum horizontal travel before a press turns into a drag.
    private static let dragThreshold: CGFloat = 4

    var onTileClick: ((Int) -> Void)?
    var onTileReorder: ((Int, Int) -> Void)?

    var content = Content(model: IndicatorModel(tiles: [], focusedIndex: nil, visibleRange: 0...1),
                          icons: [], layout: StripIndicatorLayout(tileCount: 0, maxWidth: 0)) {
        didSet {
            if content.model.tiles.count != oldValue.model.tiles.count { drag = nil }
            needsDisplay = true
        }
    }

    private var drag: DragState?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let layout = content.layout
        drawTrack(layout)
        let count = content.model.tiles.count
        let target = dropSlot()
        for index in 0..<count where index != drag?.from || drag?.isDragging != true {
            let slot = target.map { layout.displacedSlot(of: index, draggingFrom: $0.from, to: $0.to) } ?? index
            drawTile(index, in: layout.tileRect(at: slot))
        }
        if let drag, drag.isDragging, drag.from < count {
            drawTile(drag.from, in: draggedRect(drag, layout: layout), lifted: true)
        }
    }

    private func drawTrack(_ layout: StripIndicatorLayout) {
        let track = layout.trackRect
        let radius = track.height / 2
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let highlight = layout.trackHighlight(for: content.model.visibleRange)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: highlight, xRadius: radius, yRadius: radius).fill()
    }

    private func drawTile(_ index: Int, in rect: CGRect, lifted: Bool = false) {
        let tile = content.model.tiles[index]
        let isFocused = content.model.focusedIndex == index
        if isFocused { drawFocusRing(around: rect) }
        if content.icons.indices.contains(index) {
            content.icons[index].draw(in: rect, from: .zero, operation: .sourceOver, fraction: lifted ? 0.85 : 1)
        }
        if tile.isPinned { drawPin(on: rect) }
        if tile.windowCount > 1 { drawBadge(tile.windowCount, on: rect) }
    }

    private func drawFocusRing(around rect: CGRect) {
        let ringRect = rect.insetBy(dx: -4, dy: -4)
        let radius = ringRect.width * 0.26
        let path = NSBezierPath(roundedRect: ringRect, xRadius: radius, yRadius: radius)
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawBadge(_ count: Int, on rect: CGRect) {
        let diameter = max(12, rect.width * 0.44)
        let badge = CGRect(x: rect.maxX - diameter * 0.7, y: rect.maxY - diameter * 0.7,
                           width: diameter, height: diameter)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let text = count > 9 ? "9+" : "\(count)"
        let font = NSFont.systemFont(ofSize: diameter * 0.62, weight: .bold)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
    }

    private func drawPin(on rect: CGRect) {
        let diameter = max(12, rect.width * 0.44)
        let circle = CGRect(x: rect.minX - diameter * 0.3, y: rect.maxY - diameter * 0.7,
                            width: diameter, height: diameter)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: circle).fill()
        guard let glyph = Self.pinGlyph(pointSize: diameter * 0.55) else { return }
        let size = glyph.size
        glyph.draw(in: CGRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    private static func pinGlyph(pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(config)
    }

    // MARK: - Dragging

    private func draggedRect(_ drag: DragState, layout: StripIndicatorLayout) -> CGRect {
        let base = layout.tileRect(at: drag.from)
        let first = layout.tileRect(at: 0).minX
        let last = layout.tileRect(at: max(0, layout.tileCount - 1)).minX
        let x = min(max(base.minX + drag.currentX - drag.startX, first), last)
        return CGRect(x: x, y: base.minY + 3, width: base.width, height: base.height)
    }

    /// The (from, to) pair of an active drag, nil when not dragging.
    private func dropSlot() -> (from: Int, to: Int)? {
        guard let drag, drag.isDragging else { return nil }
        let rect = draggedRect(drag, layout: content.layout)
        return (drag.from, content.layout.slot(forCenterX: rect.midX))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = content.layout.tileIndex(at: point) else { drag = nil; return }
        drag = DragState(from: index, startX: point.x, currentX: point.x, isDragging: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag else { return }
        current.currentX = convert(event.locationInWindow, from: nil).x
        let canDrag = content.model.tiles.indices.contains(current.from)
            && !content.model.tiles[current.from].isPinned
        if canDrag, abs(current.currentX - current.startX) > Self.dragThreshold {
            current.isDragging = true
        }
        drag = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        guard let current = drag else { return }
        if current.isDragging {
            if let slot = dropSlot(), slot.to != slot.from { onTileReorder?(slot.from, slot.to) }
        } else {
            let point = convert(event.locationInWindow, from: nil)
            if content.layout.tileIndex(at: point) == current.from { onTileClick?(current.from) }
        }
    }
}
