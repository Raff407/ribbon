import CoreGraphics
import Foundation

/// Pure layout math. All rects are AX space.
public enum LayoutEngine {
    /// `visibleFrame` inset by `config.outerGap` on every side (never negative).
    public static func workingArea(visibleFrame: CGRect, config: LayoutConfig) -> CGRect {
        let inset = CGFloat(max(0, config.outerGap))
        let width = max(0, visibleFrame.width - 2 * inset)
        let height = max(0, visibleFrame.height - 2 * inset)
        return CGRect(x: visibleFrame.minX + inset, y: visibleFrame.minY + inset, width: width, height: height)
    }

    /// Pixel width of a column: `f * (areaWidth + gap) - gap` where `f` is the effective
    /// width fraction. So two 0.5 columns plus one gap exactly fill the area, and 1.0 is
    /// exactly the area width. Never less than 1.
    public static func columnWidth(_ column: Column, areaWidth: Double, config: LayoutConfig) -> Double {
        max(1, column.effectiveWidthFraction * (areaWidth + config.gap) - config.gap)
    }

    /// The part of `area` the non-pinned columns scroll in: `area` minus each pinned
    /// column's width and one gap per pinned column.
    public static func scrollableArea(_ strip: Strip, area: CGRect, config: LayoutConfig) -> CGRect {
        var minX = Double(area.minX)
        var maxX = Double(area.maxX)
        if let i = strip.leftPinnedColumnIndex {
            minX += columnWidth(strip.columns[i], areaWidth: Double(area.width), config: config) + config.gap
        }
        if let i = strip.rightPinnedColumnIndex {
            maxX -= columnWidth(strip.columns[i], areaWidth: Double(area.width), config: config) + config.gap
        }
        return CGRect(x: minX, y: Double(area.minY), width: max(0, maxX - minX), height: Double(area.height))
    }

    /// Total width of the non-pinned columns including the gaps between them.
    public static func stripWidth(_ strip: Strip, area: CGRect, config: LayoutConfig) -> Double {
        let widths = strip.scrollableColumnIndices.map {
            columnWidth(strip.columns[$0], areaWidth: Double(area.width), config: config)
        }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + config.gap * Double(widths.count - 1)
    }

    /// Strip-space x range (left, right) of the column at `index` (non-pinned only;
    /// returns nil for pinned or invalid indices).
    public static func stripSpan(ofColumn index: Int, in strip: Strip, area: CGRect, config: LayoutConfig) -> ClosedRange<Double>? {
        guard strip.columns.indices.contains(index), strip.columns[index].pin == nil else { return nil }
        return stripSpans(strip, area: area, config: config)[index]
    }

    /// Frames and visibility for every window in the strip.
    ///
    /// * Pinned-left column at `area.minX`, pinned-right column flush with `area.maxX`;
    ///   always `.visible`.
    /// * Non-pinned column i: `x = scrollable.minX + stripX(i) - viewportOffset`.
    /// * Stacked column: windows split `area.height - gap * (n-1)` by `heightWeights`,
    ///   top to bottom from `area.minY`, `gap` between them.
    /// * Tabbed column: the active window gets the full area height minus
    ///   `config.tabBarHeight` (it starts `tabBarHeight` below `area.minY`, leaving room
    ///   for the tab bar overlay); the others are `.hidden` (side: whichever screen edge
    ///   the column centre is nearer).
    /// * Visibility of non-pinned columns is judged against the scrollable area with a
    ///   1pt tolerance: fully inside → `.visible`; fully outside → `.hidden(side)`;
    ///   otherwise `.partial`, unless the edge it crosses is in `context.blockedSides`
    ///   or is next to a pinned column, in which case `.hidden(side)`. The focused column
    ///   is never hidden (at worst `.partial`), so focus is always on screen.
    /// * Frames are rounded to whole points.
    public static func placements(_ strip: Strip, context: LayoutContext, config: LayoutConfig) -> [WindowPlacement] {
        let area = context.area
        let scrollable = scrollableArea(strip, area: area, config: config)
        let spans = stripSpans(strip, area: area, config: config)
        let blocked = context.blockedSides
        var result: [WindowPlacement] = []
        result.reserveCapacity(strip.allWindows.count)
        for (index, column) in strip.columns.enumerated() {
            let width = columnWidth(column, areaWidth: Double(area.width), config: config)
            let x: Double
            let visibility: Visibility
            switch column.pin {
            case .left:
                x = Double(area.minX)
                visibility = .visible
            case .right:
                x = Double(area.maxX) - width
                visibility = .visible
            case nil:
                let span = spans[index] ?? 0...width
                x = Double(scrollable.minX) + span.lowerBound - strip.viewportOffset
                visibility = columnVisibility(
                    x: x, width: width, scrollable: scrollable, strip: strip,
                    blocked: blocked, isFocused: index == strip.focusedColumnIndex
                )
            }
            result += rows(of: column, columnIndex: index, x: x, width: width, visibility: visibility,
                           strip: strip, context: context, config: config)
        }
        return result
    }

    /// Adjusts `viewportOffset` so the focused column is shown according to
    /// `config.centreMode`:
    /// * `.never`: scroll the minimum amount that brings the column fully into view.
    /// * `.onOverflow`: offset 0 while the whole strip fits; otherwise keep the offset if
    ///   the column is already fully visible, else centre it.
    /// * `.always`: centre the column (not clamped).
    /// For `.never` and `.onOverflow` the result is clamped to
    /// `0 ... max(0, stripWidth - scrollableWidth)`; a column wider than the scrollable
    /// area is left-aligned. Pinned focused column → unchanged.
    public static func revealFocused(_ strip: Strip, area: CGRect, config: LayoutConfig) -> Strip {
        guard let f = strip.focusedColumnIndex,
              let span = stripSpan(ofColumn: f, in: strip, area: area, config: config) else { return strip }
        let width = Double(scrollableArea(strip, area: area, config: config).width)
        let total = stripWidth(strip, area: area, config: config)
        let current = strip.viewportOffset
        let fullyVisible = span.lowerBound >= current - 0.5 && span.upperBound <= current + width + 0.5
        var offset: Double
        switch config.centreMode {
        case .always:
            return strip.withViewportOffset(centred(span, width: width))
        case .never:
            if span.lowerBound < current {
                offset = span.lowerBound
            } else if span.upperBound > current + width {
                offset = span.upperBound - width
            } else {
                offset = current
            }
        case .onOverflow:
            if total <= width {
                offset = 0
            } else {
                offset = fullyVisible ? current : centred(span, width: width)
            }
        }
        offset = clamp(offset, total: total, width: width)
        if span.upperBound - span.lowerBound > width {
            offset = span.lowerBound
        }
        return strip.withViewportOffset(offset)
    }

    /// Clamps `viewportOffset` into `0 ... max(0, stripWidth - scrollableWidth)` unless the
    /// centre mode is `.always`.
    public static func clampViewport(_ strip: Strip, area: CGRect, config: LayoutConfig) -> Strip {
        guard config.centreMode != .always else { return strip }
        let width = Double(scrollableArea(strip, area: area, config: config).width)
        let total = stripWidth(strip, area: area, config: config)
        return strip.withViewportOffset(clamp(strip.viewportOffset, total: total, width: width))
    }

    /// Settles the strip after a trackpad/scroll gesture.
    /// `velocity` is in points/second of viewport movement (positive = viewport moving
    /// right, i.e. content moving left). The offset is projected by `velocity * 0.15`,
    /// then snapped so the nearest column's left edge (`.never`/`.onOverflow`; the
    /// right-aligned end of the strip also counts) or centre (`.always`) aligns with the
    /// scrollable area's left edge / centre, then clamped as in `clampViewport`. Focus:
    /// kept if the previously focused column is fully visible afterwards (or pinned),
    /// otherwise moved to the most visible column (ties → nearest the centre, then leftmost).
    public static func snap(_ strip: Strip, area: CGRect, config: LayoutConfig, velocity: Double) -> Strip {
        let spans = stripSpans(strip, area: area, config: config)
        guard !spans.isEmpty else { return clampViewport(strip, area: area, config: config) }
        let width = Double(scrollableArea(strip, area: area, config: config).width)
        let total = stripWidth(strip, area: area, config: config)
        let projected = strip.viewportOffset + velocity * 0.15
        let offset: Double
        if config.centreMode == .always {
            let centre = projected + width / 2
            let best = spans.values.min { abs(mid($0) - centre) < abs(mid($1) - centre) }
            offset = best.map { centred($0, width: width) } ?? projected
        } else {
            var candidates = spans.values.map(\.lowerBound)
            candidates.append(max(0, total - width))
            let best = candidates.min { abs($0 - projected) < abs($1 - projected) } ?? projected
            offset = clamp(best, total: total, width: width)
        }
        let snapped = strip.withViewportOffset(offset)
        return snapped.focusingMostVisible(spans: spans, width: width)
    }

    /// Where to park a hidden window of `size` on `screen`: its top-left corner goes to
    /// the bottom corner on `side` so only `sliver` points remain on screen —
    /// right: `(screen.maxX - sliver, screen.maxY - sliver)`;
    /// left: `(screen.minX - size.width + sliver, screen.maxY - sliver)`.
    /// If that rect intersects any of `otherScreens`, the other side is tried; if both
    /// intersect, the side with the smaller intersection area wins.
    public static func parkedFrame(size: CGSize, side: Side, screen: CGRect, otherScreens: [CGRect], sliver: Double) -> CGRect {
        func rect(_ s: Side) -> CGRect {
            let x = s == .right ? Double(screen.maxX) - sliver : Double(screen.minX) - Double(size.width) + sliver
            return CGRect(x: x, y: Double(screen.maxY) - sliver, width: Double(size.width), height: Double(size.height))
        }
        func overlap(_ r: CGRect) -> CGFloat { otherScreens.reduce(0) { $0 + r.intersectionArea(with: $1) } }
        let primary = rect(side)
        let primaryOverlap = overlap(primary)
        guard primaryOverlap > 0 else { return primary }
        let alternative = rect(side.opposite)
        let alternativeOverlap = overlap(alternative)
        return alternativeOverlap < primaryOverlap ? alternative : primary
    }

    /// Turns placements into frame transitions, given where windows currently are.
    ///
    /// * Visible/partial window: `target = placement.frame`. If the window is currently
    ///   parked or off-screen (current frame unknown, or less than 10% of its area on
    ///   `context.screenFrame`), `start` = target slid horizontally to just off the screen
    ///   edge nearer to `target.midX` (leaving `parkingSliver` visible).
    /// * Hidden(side) window: `target` = placement frame slid horizontally to just past
    ///   that screen edge (`parkingSliver` visible, so it never travels further than
    ///   needed), `final` = `parkedFrame(...)`. If the window is already parked/off-screen,
    ///   `target` = parked frame, no final.
    /// * Windows not in `placements` are not included.
    public static func transitions(
        _ placements: [WindowPlacement],
        currentFrames: [WindowID: CGRect],
        context: LayoutContext,
        config: LayoutConfig
    ) -> [WindowID: FrameTransition] {
        let screen = context.screenFrame
        let sliver = config.parkingSliver
        var result: [WindowID: FrameTransition] = [:]
        for placement in placements {
            let target = placement.frame
            let current = currentFrames[placement.window]
            let offScreen = current.map { isMostlyOffScreen($0, screen: screen) } ?? true
            switch placement.visibility {
            case .visible, .partial:
                let start: CGRect? = offScreen
                    ? edgeFrame(for: target, side: target.midX >= screen.midX ? .right : .left, screen: screen, sliver: sliver)
                    : nil
                result[placement.window] = FrameTransition(start: start, target: target)
            case .hidden(let side):
                let parked = parkedFrame(size: target.size, side: side, screen: screen,
                                         otherScreens: context.otherScreens, sliver: sliver)
                if offScreen {
                    result[placement.window] = FrameTransition(target: parked)
                } else {
                    let slid = edgeFrame(for: target, side: side, screen: screen, sliver: sliver)
                    result[placement.window] = FrameTransition(target: slid, final: parked)
                }
            }
        }
        return result
    }

    /// Index of the column whose (visible or partial) placement contains `point.x`
    /// within its rows' vertical bounds; nil when none. Used for drag-to-reorder.
    public static func columnIndex(at point: CGPoint, placements: [WindowPlacement]) -> Int? {
        for placement in placements where placement.visibility != .hidden(.left) && placement.visibility != .hidden(.right) {
            let f = placement.frame
            if point.x >= f.minX && point.x <= f.maxX {
                let column = placements.filter { $0.columnIndex == placement.columnIndex }
                let top = column.map(\.frame.minY).min() ?? f.minY
                let bottom = column.map(\.frame.maxY).max() ?? f.maxY
                if point.y >= top && point.y <= bottom { return placement.columnIndex }
            }
        }
        return nil
    }
}

// MARK: - Internals

extension LayoutEngine {
    /// Strip-space spans of every non-pinned column, keyed by column index.
    static func stripSpans(_ strip: Strip, area: CGRect, config: LayoutConfig) -> [Int: ClosedRange<Double>] {
        var spans: [Int: ClosedRange<Double>] = [:]
        var x = 0.0
        for index in strip.scrollableColumnIndices {
            let width = columnWidth(strip.columns[index], areaWidth: Double(area.width), config: config)
            spans[index] = x...(x + width)
            x += width + config.gap
        }
        return spans
    }

    static func columnVisibility(
        x: Double, width: Double, scrollable: CGRect, strip: Strip, blocked: Set<Side>, isFocused: Bool
    ) -> Visibility {
        let tolerance = 1.0
        let lower = Double(scrollable.minX)
        let upper = Double(scrollable.maxX)
        let right = x + width
        if x >= lower - tolerance && right <= upper + tolerance { return .visible }
        let side: Side = x < lower - tolerance ? .left : .right
        if !isFocused {
            if right <= lower { return .hidden(.left) }
            if x >= upper { return .hidden(.right) }
            let pinnedOnSide = side == .left ? strip.leftPinnedColumnIndex != nil : strip.rightPinnedColumnIndex != nil
            if blocked.contains(side) || pinnedOnSide { return .hidden(side) }
        }
        return .partial
    }

    static func rows(
        of column: Column, columnIndex: Int, x: Double, width: Double, visibility: Visibility,
        strip: Strip, context: LayoutContext, config: LayoutConfig
    ) -> [WindowPlacement] {
        let area = context.area
        let isFocusedColumn = columnIndex == strip.focusedColumnIndex
        let tabSide: Side = x + width / 2 < Double(context.screenFrame.midX) ? .left : .right
        if column.mode == .tabbed {
            let bar = min(max(0, config.tabBarHeight), Double(area.height) / 2)
            let frame = CGRect(x: x, y: Double(area.minY) + bar, width: width, height: Double(area.height) - bar).roundedToPoints
            return column.windows.enumerated().map { row, window in
                let active = row == column.activeIndex
                return WindowPlacement(
                    window: window, frame: frame, visibility: active ? visibility : .hidden(tabSide),
                    columnIndex: columnIndex, row: row, isFocused: active && isFocusedColumn
                )
            }
        }
        let count = column.windows.count
        let available = max(0, Double(area.height) - config.gap * Double(count - 1))
        let total = column.heightWeights.reduce(0, +)
        var y = Double(area.minY)
        var result: [WindowPlacement] = []
        for (row, window) in column.windows.enumerated() {
            let weight = column.heightWeights.indices.contains(row) ? column.heightWeights[row] : 1
            let height = total > 0 ? available * weight / total : available / Double(count)
            let frame = CGRect(x: x, y: y, width: width, height: height).roundedToPoints
            result.append(WindowPlacement(
                window: window, frame: frame, visibility: visibility, columnIndex: columnIndex, row: row,
                isFocused: isFocusedColumn && row == column.activeIndex
            ))
            y += height + config.gap
        }
        return result
    }

    static func clamp(_ offset: Double, total: Double, width: Double) -> Double {
        offset.clamped(to: 0...max(0, total - width))
    }

    static func mid(_ span: ClosedRange<Double>) -> Double { (span.lowerBound + span.upperBound) / 2 }

    static func centred(_ span: ClosedRange<Double>, width: Double) -> Double { mid(span) - width / 2 }

    static func isMostlyOffScreen(_ frame: CGRect, screen: CGRect) -> Bool {
        let area = frame.width * frame.height
        guard area > 0 else { return true }
        return frame.intersectionArea(with: screen) / area < 0.1
    }

    /// `frame` slid horizontally to just past `side`'s screen edge.
    static func edgeFrame(for frame: CGRect, side: Side, screen: CGRect, sliver: Double) -> CGRect {
        var r = frame
        r.origin.x = side == .right ? screen.maxX - CGFloat(sliver) : screen.minX - frame.width + CGFloat(sliver)
        return r
    }
}

extension Strip {
    func withViewportOffset(_ offset: Double) -> Strip {
        Strip(columns: columns, focusedColumnIndex: focusedColumnIndex, viewportOffset: offset)
    }

    /// Keeps focus if the focused column is pinned or fully visible, else focuses the
    /// non-pinned column with the most visible width (ties → nearest the viewport centre).
    func focusingMostVisible(spans: [Int: ClosedRange<Double>], width: Double) -> Strip {
        let lower = viewportOffset
        let upper = viewportOffset + width
        func visible(_ s: ClosedRange<Double>) -> Double { max(0, min(s.upperBound, upper) - max(s.lowerBound, lower)) }
        if let f = focusedColumnIndex {
            guard let span = spans[f] else { return self }
            if span.lowerBound >= lower - 0.5 && span.upperBound <= upper + 0.5 { return self }
        }
        let centre = (lower + upper) / 2
        let best = spans.max { a, b in
            let va = visible(a.value), vb = visible(b.value)
            if abs(va - vb) > 0.5 { return va < vb }
            let da = abs(LayoutEngine.mid(a.value) - centre), db = abs(LayoutEngine.mid(b.value) - centre)
            if abs(da - db) > 0.5 { return da > db }
            return a.key > b.key
        }
        guard let index = best?.key else { return self }
        return Strip(columns: columns, focusedColumnIndex: index, viewportOffset: viewportOffset)
    }
}
