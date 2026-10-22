import Foundation

public struct WindowLocation: Equatable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// One endless horizontal strip of columns. There is one strip per (display, Space).
///
/// Invariants (every operation returning a Strip must preserve them):
/// * `focusedColumnIndex == nil` iff `columns.isEmpty`; otherwise it is a valid index.
/// * No window id appears twice in the strip.
/// * At most one column has `pin == .left` and it is at index 0; at most one has
///   `pin == .right` and it is the last column. A column can't be both.
/// * Every column satisfies the `Column` invariants.
/// * Only the focused column can be full width: full width lasts while the column has
///   focus and reverts to its own width when focus moves on, so a maximised window never
///   ends up half off-screen next to the one you're using.
public struct Strip: Equatable, Codable, Sendable {
    public var columns: [Column]
    public var focusedColumnIndex: Int?
    /// Horizontal scroll position: strip-space x (points) of the left edge of the
    /// scrollable area. Strip space starts at 0 at the left edge of the first
    /// non-pinned column. May be negative (blank space on the left) in `.always`
    /// centre mode or after an explicit centre.
    public var viewportOffset: Double

    public init(columns: [Column] = [], focusedColumnIndex: Int? = nil, viewportOffset: Double = 0) {
        let focus = columns.isEmpty ? nil : (focusedColumnIndex ?? 0)
        self.columns = columns.enumerated().map { index, column in
            guard column.isFullWidth, index != focus else { return column }
            var released = column
            released.isFullWidth = false
            return released
        }
        self.focusedColumnIndex = focus
        self.viewportOffset = viewportOffset
    }

    public var isEmpty: Bool { columns.isEmpty }

    public var focusedColumn: Column? {
        guard let i = focusedColumnIndex, columns.indices.contains(i) else { return nil }
        return columns[i]
    }

    /// The active window of the focused column.
    public var focusedWindow: WindowID? { focusedColumn?.activeWindow }

    /// All windows, column by column, top to bottom.
    public var allWindows: [WindowID] { columns.flatMap(\.windows) }

    public func location(of window: WindowID) -> WindowLocation? {
        for (c, column) in columns.enumerated() {
            if let r = column.windows.firstIndex(of: window) {
                return WindowLocation(column: c, row: r)
            }
        }
        return nil
    }

    public func contains(_ window: WindowID) -> Bool { location(of: window) != nil }

    public var leftPinnedColumnIndex: Int? {
        columns.first?.pin == .left ? 0 : nil
    }

    public var rightPinnedColumnIndex: Int? {
        guard let last = columns.indices.last, columns[last].pin == .right else { return nil }
        return last
    }

    /// Indices of the columns that scroll (i.e. not pinned), in order.
    public var scrollableColumnIndices: [Int] {
        columns.indices.filter { columns[$0].pin == nil }
    }
}
