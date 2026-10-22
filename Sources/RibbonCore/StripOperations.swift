import CoreGraphics
import Foundation

/// Where a newly tiled window goes.
public enum InsertPosition: Equatable, Sendable {
    /// A new column immediately right of the focused column (or at the end when the
    /// strip is empty). Never lands outside a right-pinned column: it goes before it.
    case afterFocused
    /// A new column at the end of the scrollable columns (before a right-pinned column).
    case end
    /// A new column at this index in `columns` (clamped into the scrollable range so
    /// pins stay at the edges).
    case at(Int)
}

// All operations are pure: they return a new Strip and never mutate `self`.
// Operations that don't apply (e.g. focus left at the first column) return `self`
// unchanged. Viewport adjustments are NOT done here — the engine calls
// `LayoutEngine.revealFocused` after an operation that changes focus/structure,
// except where documented (centreColumn).
public extension Strip {
    /// Adds `window` as a new single-window column.
    /// - Parameters:
    ///   - focus: when true the new column becomes focused; otherwise focus stays on
    ///     the same column it was on before (its index may shift by one).
    ///   - widthFraction: width of the new column.
    /// If `window` is already in the strip, returns `self`.
    func inserting(_ window: WindowID, position: InsertPosition, widthFraction: Double, focus: Bool) -> Strip {
        guard !contains(window) else { return self }
        let range = insertableRange
        let index: Int
        switch position {
        case .afterFocused:
            index = (focusedColumnIndex.map { $0 + 1 } ?? range.upperBound).clamped(to: range)
        case .end:
            index = range.upperBound
        case .at(let i):
            index = i.clamped(to: range)
        }
        var newColumns = columns
        newColumns.insert(Column(windows: [window], widthFraction: widthFraction), at: index)
        let newFocus: Int
        if focus || focusedColumnIndex == nil {
            newFocus = index
        } else {
            let f = focusedColumnIndex ?? 0
            newFocus = index <= f ? f + 1 : f
        }
        return Strip(columns: newColumns, focusedColumnIndex: newFocus, viewportOffset: viewportOffset)
    }

    /// Removes `window`. If its column becomes empty the column is removed.
    /// Focus: if the removed window's column was focused and is gone, focus moves to the
    /// column on the left (or the new first column). If the column survives, its
    /// `activeIndex` is clamped (prefers the window above the removed one).
    /// Height weights of the remaining windows are kept.
    /// Returns `self` when the window isn't in the strip.
    func removing(_ window: WindowID) -> Strip {
        guard let loc = location(of: window) else { return self }
        var newColumns = columns
        let column = columns[loc.column].removingRow(loc.row)
        guard let survivor = column else {
            newColumns.remove(at: loc.column)
            guard !newColumns.isEmpty else { return Strip(columns: [], viewportOffset: viewportOffset) }
            var f = focusedColumnIndex ?? 0
            if f == loc.column {
                f = max(0, loc.column - 1)
            } else if f > loc.column {
                f -= 1
            }
            return Strip(columns: newColumns, focusedColumnIndex: min(f, newColumns.count - 1), viewportOffset: viewportOffset)
        }
        newColumns[loc.column] = survivor
        return Strip(columns: newColumns, focusedColumnIndex: focusedColumnIndex, viewportOffset: viewportOffset)
    }

    /// Focuses `window`: its column becomes focused and its row becomes the column's
    /// `activeIndex`. Returns `self` when the window isn't in the strip.
    func focusing(_ window: WindowID) -> Strip {
        guard let loc = location(of: window) else { return self }
        var newColumns = columns
        newColumns[loc.column].activeIndex = loc.row
        return Strip(columns: newColumns, focusedColumnIndex: loc.column, viewportOffset: viewportOffset)
    }

    /// Replaces `old` with `new` in place (same column/row/weights). Used for native
    /// macOS window tabs, where switching tab swaps which window is on screen.
    /// Returns `self` if `old` is missing or `new` is already in the strip.
    func replacing(_ old: WindowID, with new: WindowID) -> Strip {
        guard let loc = location(of: old), !contains(new) else { return self }
        var newColumns = columns
        newColumns[loc.column].windows[loc.row] = new
        return Strip(columns: newColumns, focusedColumnIndex: focusedColumnIndex, viewportOffset: viewportOffset)
    }

    /// Moves the column at `from` so that it ends up at index `to` (both clamped into the
    /// scrollable range; pinned columns can't be moved this way). Focus follows the
    /// moved column if it was focused, otherwise stays on the same column.
    func movingColumn(from: Int, to: Int) -> Strip {
        guard columns.indices.contains(from), columns[from].pin == nil, let range = scrollableIndexRange else { return self }
        let target = to.clamped(to: range)
        guard target != from else { return self }
        var newColumns = columns
        let moved = newColumns.remove(at: from)
        newColumns.insert(moved, at: target)
        let f = focusedColumnIndex ?? 0
        let newFocus: Int
        if f == from {
            newFocus = target
        } else if from < f && target >= f {
            newFocus = f - 1
        } else if from > f && target <= f {
            newFocus = f + 1
        } else {
            newFocus = f
        }
        return Strip(columns: newColumns, focusedColumnIndex: newFocus, viewportOffset: viewportOffset)
    }

    /// Sets the width fraction of the column containing `window` (clamped to
    /// `config.minWidthFraction ... 1`) and clears `isFullWidth`. Used when the user
    /// resizes a tiled window with the mouse.
    func settingWidthFraction(_ fraction: Double, ofColumnContaining window: WindowID, config: LayoutConfig) -> Strip {
        guard let loc = location(of: window) else { return self }
        var newColumns = columns
        newColumns[loc.column].widthFraction = fraction.clamped(to: config.minWidthFraction...1)
        newColumns[loc.column].isFullWidth = false
        return Strip(columns: newColumns, focusedColumnIndex: focusedColumnIndex, viewportOffset: viewportOffset)
    }

    /// Sets the height share (0...1 of the column) of `window` in a stacked column with
    /// more than one window, taking/giving the difference proportionally from/to the
    /// others; no share below 0.1. Used when the user resizes a stacked window.
    func settingHeightShare(_ share: Double, of window: WindowID) -> Strip {
        guard let loc = location(of: window) else { return self }
        guard let column = columns[loc.column].withShare(share, forRow: loc.row) else { return self }
        var newColumns = columns
        newColumns[loc.column] = column
        return Strip(columns: newColumns, focusedColumnIndex: focusedColumnIndex, viewportOffset: viewportOffset)
    }

    /// Applies a strip-level command (`command.isStripCommand == true`); returns `self`
    /// for anything else. `area` is the working area (visible frame already inset by the
    /// outer gap — see `LayoutEngine.workingArea`), needed for `.centreColumn`.
    ///
    /// Semantics:
    /// * `.focus(.left/.right)`: focused column ∓/± 1, no wrap-around (pinned columns
    ///   take part in navigation order like any other column).
    /// * `.focus(.up/.down)`: focused column's `activeIndex` ∓/± 1, no wrap (works for
    ///   stacked and tabbed columns).
    /// * `.focusFirst/.focusLast`: first/last column. `.focusColumn(n)`: column n-1 if it exists.
    /// * `.move(.left/.right)`: swap the focused column with its neighbour; focus follows.
    ///   Pinned columns don't move, and nothing moves past a pinned column.
    /// * `.move(.up/.down)`: swap the active window with the one above/below in its column.
    /// * `.moveFirst/.moveLast`: move the focused (non-pinned) column to the start/end of
    ///   the scrollable columns.
    /// * `.cycleWidth`: next entry of `config.widthPresets` (sorted ascending) strictly
    ///   greater than the current effective fraction (epsilon 0.01), wrapping to the
    ///   smallest; clears `isFullWidth`. `.cycleWidthBackward` is the reverse.
    /// * `.toggleFullWidth`: toggles `isFullWidth`.
    /// * `.centreColumn`: sets `viewportOffset` so the focused column is centred in the
    ///   scrollable area (not clamped). No-op for pinned columns.
    /// * `.wider/.narrower`: ± `config.widthStep` on the effective fraction, clamped to
    ///   `config.minWidthFraction ... 1`; clears `isFullWidth`.
    /// * `.taller/.shorter`: in a stacked column with >1 window, grow/shrink the active
    ///   window's share of the height by `config.heightStep` (as a fraction of the total),
    ///   taking/giving it proportionally from/to the others; no share below 0.1.
    /// * `.equalizeHeights`: all weights equal.
    /// * `.pinLeft/.pinRight`: if the focused column already has that pin, unpin it (it
    ///   stays where it is as a normal column). Otherwise unpin any column holding that
    ///   pin, remove any other pin from the focused column, and move it to index 0 (left)
    ///   or last (right) with the pin set. Focus follows.
    /// * `.stackIntoLeft/.stackIntoRight`: move the focused column's active window to the
    ///   bottom of the neighbouring column on that side (which becomes focused, with the
    ///   moved window active). If the source column becomes empty it's removed. No-op
    ///   without a neighbour.
    /// * `.popOutLeft/.popOutRight`: if the focused column has >1 window, take its active
    ///   window into a new column on that side (same width fraction as the source); the
    ///   new column is focused. No-op for single-window columns.
    /// * `.toggleTabbed`: toggles `mode` between `.stacked` and `.tabbed`.
    func applying(_ command: Command, area: CGRect, config: LayoutConfig) -> Strip {
        guard let f = focusedColumnIndex, columns.indices.contains(f) else { return self }
        switch command {
        case .focus(.left): return focusingColumn(f - 1)
        case .focus(.right): return focusingColumn(f + 1)
        case .focus(.up): return updatingColumn(f) { $0.focusingRow($0.activeIndex - 1) }
        case .focus(.down): return updatingColumn(f) { $0.focusingRow($0.activeIndex + 1) }
        case .focusFirst: return focusingColumn(0)
        case .focusLast: return focusingColumn(columns.count - 1)
        case .focusColumn(let n): return focusingColumn(n - 1)
        case .move(.left): return swappingColumn(f, with: f - 1)
        case .move(.right): return swappingColumn(f, with: f + 1)
        case .move(.up): return updatingColumn(f) { $0.swappingActiveRow(by: -1) }
        case .move(.down): return updatingColumn(f) { $0.swappingActiveRow(by: 1) }
        case .moveFirst: return scrollableIndexRange.map { movingColumn(from: f, to: $0.lowerBound) } ?? self
        case .moveLast: return scrollableIndexRange.map { movingColumn(from: f, to: $0.upperBound) } ?? self
        case .cycleWidth: return updatingColumn(f) { $0.cyclingWidth(presets: config.widthPresets, forward: true) }
        case .cycleWidthBackward: return updatingColumn(f) { $0.cyclingWidth(presets: config.widthPresets, forward: false) }
        case .toggleFullWidth: return updatingColumn(f) { $0.togglingFullWidth() }
        case .centreColumn: return centringColumn(f, area: area, config: config)
        case .wider: return updatingColumn(f) { $0.resizedWidth(by: config.widthStep, config: config) }
        case .narrower: return updatingColumn(f) { $0.resizedWidth(by: -config.widthStep, config: config) }
        case .taller: return updatingColumn(f) { $0.resizedActiveHeight(by: config.heightStep) }
        case .shorter: return updatingColumn(f) { $0.resizedActiveHeight(by: -config.heightStep) }
        case .equalizeHeights: return updatingColumn(f) { $0.equalizedHeights() }
        case .pinLeft: return pinningFocused(.left)
        case .pinRight: return pinningFocused(.right)
        case .stackIntoLeft: return stackingFocused(into: f - 1)
        case .stackIntoRight: return stackingFocused(into: f + 1)
        case .popOutLeft: return poppingOutFocused(.left)
        case .popOutRight: return poppingOutFocused(.right)
        case .toggleTabbed: return updatingColumn(f) { $0.togglingMode() }
        case .toggleFloat, .sendToNextDisplay, .toggleEnabled, .gatherWindows, .showIndicator, .openSettings:
            return self
        }
    }
}

// MARK: - Helpers

extension Strip {
    /// Indices where a new non-pinned column may be inserted.
    var insertableRange: ClosedRange<Int> {
        let lower = leftPinnedColumnIndex == nil ? 0 : 1
        let upper = rightPinnedColumnIndex == nil ? columns.count : columns.count - 1
        return lower...max(lower, upper)
    }

    /// Indices of non-pinned columns (they're contiguous), nil when there are none.
    var scrollableIndexRange: ClosedRange<Int>? {
        let indices = scrollableColumnIndices
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    func focusingColumn(_ index: Int) -> Strip {
        guard columns.indices.contains(index), index != focusedColumnIndex else { return self }
        return Strip(columns: columns, focusedColumnIndex: index, viewportOffset: viewportOffset)
    }

    func updatingColumn(_ index: Int, _ transform: (Column) -> Column?) -> Strip {
        guard columns.indices.contains(index), let updated = transform(columns[index]), updated != columns[index] else {
            return self
        }
        var newColumns = columns
        newColumns[index] = updated
        return Strip(columns: newColumns, focusedColumnIndex: focusedColumnIndex, viewportOffset: viewportOffset)
    }

    func swappingColumn(_ index: Int, with other: Int) -> Strip {
        guard columns.indices.contains(index), columns.indices.contains(other),
              columns[index].pin == nil, columns[other].pin == nil else { return self }
        var newColumns = columns
        newColumns.swapAt(index, other)
        let f = focusedColumnIndex == index ? other : focusedColumnIndex
        return Strip(columns: newColumns, focusedColumnIndex: f, viewportOffset: viewportOffset)
    }

    func centringColumn(_ index: Int, area: CGRect, config: LayoutConfig) -> Strip {
        guard let span = LayoutEngine.stripSpan(ofColumn: index, in: self, area: area, config: config) else { return self }
        let scrollable = LayoutEngine.scrollableArea(self, area: area, config: config)
        let offset = (span.lowerBound + span.upperBound) / 2 - Double(scrollable.width) / 2
        return Strip(columns: columns, focusedColumnIndex: focusedColumnIndex, viewportOffset: offset)
    }

    func pinningFocused(_ side: PinSide) -> Strip {
        guard let f = focusedColumnIndex else { return self }
        if columns[f].pin == side {
            return updatingColumn(f) { column in
                var c = column
                c.pin = nil
                return c
            }
        }
        var newColumns = columns.map { column -> Column in
            var c = column
            if c.pin == side { c.pin = nil }
            return c
        }
        var focused = newColumns.remove(at: f)
        focused.pin = side
        let target = side == .left ? 0 : newColumns.count
        newColumns.insert(focused, at: target)
        return Strip(columns: newColumns, focusedColumnIndex: target, viewportOffset: viewportOffset)
    }

    func stackingFocused(into target: Int) -> Strip {
        guard let f = focusedColumnIndex, columns.indices.contains(target), target != f,
              let window = columns[f].activeWindow else { return self }
        var newColumns = columns
        newColumns[target] = columns[target].appending(window)
        if let remaining = columns[f].removingRow(columns[f].activeIndex) {
            newColumns[f] = remaining
            return Strip(columns: newColumns, focusedColumnIndex: target, viewportOffset: viewportOffset)
        }
        newColumns.remove(at: f)
        let newFocus = target > f ? target - 1 : target
        return Strip(columns: newColumns, focusedColumnIndex: newFocus, viewportOffset: viewportOffset)
    }

    func poppingOutFocused(_ side: Side) -> Strip {
        guard let f = focusedColumnIndex, columns[f].windows.count > 1,
              let window = columns[f].activeWindow,
              let remaining = columns[f].removingRow(columns[f].activeIndex) else { return self }
        var newColumns = columns
        newColumns[f] = remaining
        let wanted = side == .left ? f : f + 1
        let lower = newColumns.first?.pin == .left ? 1 : 0
        let upper = newColumns.last?.pin == .right ? newColumns.count - 1 : newColumns.count
        let index = wanted.clamped(to: lower...max(lower, upper))
        newColumns.insert(Column(windows: [window], widthFraction: columns[f].widthFraction), at: index)
        return Strip(columns: newColumns, focusedColumnIndex: index, viewportOffset: viewportOffset)
    }
}

extension Column {
    /// The column without `row`, or nil when that leaves it empty.
    func removingRow(_ row: Int) -> Column? {
        guard windows.indices.contains(row), windows.count > 1 else { return nil }
        var c = self
        c.windows.remove(at: row)
        c.heightWeights.remove(at: row)
        if row < activeIndex {
            c.activeIndex = activeIndex - 1
        } else if row == activeIndex {
            c.activeIndex = max(0, row - 1)
        }
        c.activeIndex = min(c.activeIndex, c.windows.count - 1)
        return c
    }

    /// Appends `window` at the bottom (weight = mean of the existing weights) and makes it active.
    func appending(_ window: WindowID) -> Column {
        var c = self
        let mean = heightWeights.isEmpty ? 1 : heightWeights.reduce(0, +) / Double(heightWeights.count)
        c.windows.append(window)
        c.heightWeights.append(mean)
        c.activeIndex = c.windows.count - 1
        return c
    }

    func focusingRow(_ row: Int) -> Column? {
        guard windows.indices.contains(row) else { return nil }
        var c = self
        c.activeIndex = row
        return c
    }

    func swappingActiveRow(by delta: Int) -> Column? {
        let other = activeIndex + delta
        guard windows.indices.contains(other) else { return nil }
        var c = self
        c.windows.swapAt(activeIndex, other)
        c.heightWeights.swapAt(activeIndex, other)
        c.activeIndex = other
        return c
    }

    func cyclingWidth(presets: [Double], forward: Bool) -> Column? {
        let sorted = Array(Set(presets.filter { $0 > 0 && $0 <= 1 })).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let current = effectiveWidthFraction
        let epsilon = 0.01
        let next = forward
            ? (sorted.first { $0 > current + epsilon } ?? first)
            : (sorted.last { $0 < current - epsilon } ?? last)
        var c = self
        c.widthFraction = next
        c.isFullWidth = false
        return c
    }

    func togglingFullWidth() -> Column {
        var c = self
        c.isFullWidth.toggle()
        return c
    }

    func resizedWidth(by delta: Double, config: LayoutConfig) -> Column {
        var c = self
        c.widthFraction = (effectiveWidthFraction + delta).clamped(to: config.minWidthFraction...1)
        c.isFullWidth = false
        return c
    }

    func resizedActiveHeight(by delta: Double) -> Column? {
        guard mode == .stacked, windows.count > 1 else { return nil }
        let total = heightWeights.reduce(0, +)
        guard total > 0 else { return nil }
        return withShare(heightWeights[activeIndex] / total + delta, forRow: activeIndex)
    }

    /// Sets `row`'s share of the height (others scale proportionally, none below 0.1).
    /// Returns nil if the column isn't a stack or nothing changes.
    func withShare(_ wanted: Double, forRow row: Int) -> Column? {
        let minShare = 0.1
        guard mode == .stacked, windows.count > 1, windows.indices.contains(row) else { return nil }
        let total = heightWeights.reduce(0, +)
        guard total > 0 else { return nil }
        let shares = heightWeights.map { $0 / total }
        let current = shares[row]
        let othersTotal = 1 - current
        var share = wanted.clamped(to: minShare...(1 - minShare * Double(windows.count - 1)))
        if othersTotal > 0 {
            for (i, s) in shares.enumerated() where i != row && s > 0 {
                share = min(share, 1 - minShare * othersTotal / s)
            }
        }
        share = max(share, minShare)
        guard abs(share - current) > 1e-9 else { return nil }
        let scale = othersTotal > 0 ? (1 - share) / othersTotal : 0
        var c = self
        c.heightWeights = shares.enumerated().map { i, s in
            i == row ? share : (othersTotal > 0 ? s * scale : (1 - share) / Double(windows.count - 1))
        }
        return c
    }

    func equalizedHeights() -> Column {
        var c = self
        c.heightWeights = Array(repeating: 1, count: windows.count)
        return c
    }

    func togglingMode() -> Column {
        var c = self
        c.mode = mode == .stacked ? .tabbed : .stacked
        return c
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
