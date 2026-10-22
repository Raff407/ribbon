import Foundation

public enum ColumnMode: String, Codable, Sendable {
    /// Windows split the column height, top to bottom.
    case stacked
    /// Only the active window is shown, at full column height; the others are parked.
    case tabbed
}

public enum PinSide: String, Codable, Sendable {
    case left, right
}

/// One column on the strip. Holds one or more windows (a stack).
///
/// Invariants (enforced by every RibbonCore operation that returns a Column/Strip):
/// * `windows` is non-empty for every column stored in a `Strip`.
/// * `heightWeights.count == windows.count`, every weight > 0.
/// * `0 <= activeIndex < windows.count`.
/// * `widthFraction` is in `LayoutConfig.minWidthFraction ... 1`.
public struct Column: Equatable, Codable, Sendable {
    public var windows: [WindowID]
    /// Relative heights of the windows when `mode == .stacked` (parallel to `windows`).
    public var heightWeights: [Double]
    /// Index into `windows` of the window that has (or last had) focus in this column.
    public var activeIndex: Int
    /// Width as a fraction of the working area (see `LayoutEngine.columnWidth`).
    public var widthFraction: Double
    public var mode: ColumnMode
    /// When true the column is laid out at full width; `widthFraction` is kept so that
    /// toggling full width off restores the previous width. Only the focused column of a
    /// strip keeps this (see `Strip`).
    public var isFullWidth: Bool
    /// Pinned columns stay at a screen edge while the rest of the strip scrolls.
    /// A left-pinned column is always at index 0 of `Strip.columns`, a right-pinned
    /// column always at the last index.
    public var pin: PinSide?

    public init(
        windows: [WindowID],
        heightWeights: [Double]? = nil,
        activeIndex: Int = 0,
        widthFraction: Double,
        mode: ColumnMode = .stacked,
        isFullWidth: Bool = false,
        pin: PinSide? = nil
    ) {
        self.windows = windows
        self.heightWeights = heightWeights ?? Array(repeating: 1, count: windows.count)
        self.activeIndex = activeIndex
        self.widthFraction = widthFraction
        self.mode = mode
        self.isFullWidth = isFullWidth
        self.pin = pin
    }

    public var activeWindow: WindowID? {
        windows.indices.contains(activeIndex) ? windows[activeIndex] : nil
    }

    /// The fraction actually used for layout (1 when full width).
    public var effectiveWidthFraction: Double { isFullWidth ? 1 : widthFraction }
}
