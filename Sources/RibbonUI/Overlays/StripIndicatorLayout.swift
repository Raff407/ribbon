import CoreGraphics

/// Pure geometry of the strip indicator (view coordinates, origin bottom-left).
///
/// ```
///  ┌──────────────────────────────┐
///  │  [tile] [tile] [tile] [tile] │  ← tiles row
///  │  ━━━━━━━━══════━━━━━━━━━━━━  │  ← track, highlighted part = visibleRange
///  └──────────────────────────────┘
/// ```
/// When there are too many tiles for `maxWidth`, everything scales down uniformly
/// (never below `minimumScale`).
struct StripIndicatorLayout: Equatable {
    static let baseTileSize: CGFloat = 36
    static let baseSpacing: CGFloat = 10
    static let basePadding: CGFloat = 14
    static let trackHeight: CGFloat = 3
    static let trackSpacing: CGFloat = 9
    static let minimumScale: CGFloat = 0.4

    let tileCount: Int
    let scale: CGFloat

    init(tileCount: Int, maxWidth: CGFloat) {
        self.tileCount = max(0, tileCount)
        let natural = Self.naturalWidth(tileCount: self.tileCount)
        let fit = natural > 0 && maxWidth > 0 ? maxWidth / natural : 1
        scale = max(Self.minimumScale, min(1, fit))
    }

    var tileSize: CGFloat { Self.baseTileSize * scale }
    var spacing: CGFloat { Self.baseSpacing * scale }
    var padding: CGFloat { Self.basePadding * scale }
    /// Distance between the left edges of neighbouring tiles.
    var pitch: CGFloat { tileSize + spacing }

    var size: CGSize {
        let width = padding * 2 + rowWidth
        let height = padding * 2 + tileSize + Self.trackSpacing + Self.trackHeight
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    var rowWidth: CGFloat {
        tileCount == 0 ? tileSize : CGFloat(tileCount) * tileSize + CGFloat(tileCount - 1) * spacing
    }

    /// Rect of the tile in slot `index` (no drag offset).
    func tileRect(at index: Int) -> CGRect {
        let y = padding + Self.trackHeight + Self.trackSpacing
        return CGRect(x: padding + CGFloat(index) * pitch, y: y, width: tileSize, height: tileSize)
    }

    var trackRect: CGRect {
        CGRect(x: padding, y: padding, width: rowWidth, height: Self.trackHeight)
    }

    /// The highlighted part of the track for a 0...1 visible range (at least a few
    /// points wide so it never disappears).
    func trackHighlight(for range: ClosedRange<Double>) -> CGRect {
        let track = trackRect
        let lo = CGFloat(min(max(range.lowerBound, 0), 1))
        let hi = CGFloat(min(max(range.upperBound, 0), 1))
        let minWidth = min(track.width, 6)
        let width = max(minWidth, (hi - lo) * track.width)
        let x = min(track.minX + lo * track.width, track.maxX - width)
        return CGRect(x: x, y: track.minY, width: width, height: track.height)
    }

    /// Index of the tile under `point`, if any (slightly generous hit area).
    func tileIndex(at point: CGPoint) -> Int? {
        (0..<tileCount).first { tileRect(at: $0).insetBy(dx: -spacing / 2, dy: -spacing / 2).contains(point) }
    }

    /// The slot a dragged tile whose centre is at `centerX` would drop into.
    func slot(forCenterX centerX: CGFloat) -> Int {
        guard tileCount > 0 else { return 0 }
        let firstCenter = tileRect(at: 0).midX
        let raw = Int(((centerX - firstCenter) / pitch).rounded())
        return min(max(raw, 0), tileCount - 1)
    }

    /// Where tile `index` is drawn while tile `from` is being dragged towards slot `to`:
    /// the tiles in between shift one slot to make room.
    func displacedSlot(of index: Int, draggingFrom from: Int, to: Int) -> Int {
        if from < to, index > from, index <= to { return index - 1 }
        if from > to, index >= to, index < from { return index + 1 }
        return index
    }

    static func naturalWidth(tileCount: Int) -> CGFloat {
        guard tileCount > 0 else { return 0 }
        return basePadding * 2 + CGFloat(tileCount) * baseTileSize + CGFloat(tileCount - 1) * baseSpacing
    }
}
