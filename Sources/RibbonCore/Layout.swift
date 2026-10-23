import CoreGraphics
import Foundation

public enum CentreMode: String, Codable, CaseIterable, Sendable {
    /// Scroll just far enough to bring the focused column fully into view.
    case never
    /// Left-align the strip while it fits; once it overflows, centre the focused column.
    case onOverflow
    /// Always keep the focused column centred.
    case always
}

public struct LayoutConfig: Equatable, Codable, Sendable {
    /// Space between adjacent windows (points).
    public var gap: Double
    /// Space between windows and the edges of the visible frame (points).
    public var outerGap: Double
    public var centreMode: CentreMode
    /// Width presets for cycle-width, as fractions of the working area (0...1].
    public var widthPresets: [Double]
    /// Width of a newly tiled window's column.
    public var defaultWidthFraction: Double
    /// Step for wider/narrower.
    public var widthStep: Double
    /// Step for taller/shorter (fraction of the column height).
    public var heightStep: Double
    public var minWidthFraction: Double
    /// How many points of a parked (hidden) window stay on screen. macOS refuses to put a
    /// window entirely off-screen, so hidden windows are parked in a screen corner with
    /// only this sliver visible.
    public var parkingSliver: Double
    /// Height reserved at the top of a tabbed column for its tab bar (0 = no bar).
    public var tabBarHeight: Double
    /// Focus and move left/right loop around: past the last column comes the first.
    public var wrapsAround: Bool

    public init(
        gap: Double = 8,
        outerGap: Double = 8,
        centreMode: CentreMode = .never,
        widthPresets: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0],
        defaultWidthFraction: Double = 0.5,
        widthStep: Double = 0.1,
        heightStep: Double = 0.1,
        minWidthFraction: Double = 0.1,
        parkingSliver: Double = 1,
        tabBarHeight: Double = 26,
        wrapsAround: Bool = true
    ) {
        self.gap = gap
        self.outerGap = outerGap
        self.centreMode = centreMode
        self.widthPresets = widthPresets
        self.defaultWidthFraction = defaultWidthFraction
        self.widthStep = widthStep
        self.heightStep = heightStep
        self.minWidthFraction = minWidthFraction
        self.parkingSliver = parkingSliver
        self.tabBarHeight = tabBarHeight
        self.wrapsAround = wrapsAround
    }

    public static let `default` = LayoutConfig()
}

public enum Visibility: Equatable, Sendable {
    /// Entirely inside the scrollable area (or a pinned column).
    case visible
    /// Partly inside the scrollable area, sticking out past an edge that has no
    /// neighbouring display and no pinned column.
    case partial
    /// Not shown; should be parked off to this side.
    case hidden(Side)
}

public struct WindowPlacement: Equatable, Sendable {
    public var window: WindowID
    /// Where the window sits on the strip projected into AX space. For hidden windows
    /// this may be far off-screen; `LayoutEngine.transitions` turns it into a parking spot.
    public var frame: CGRect
    public var visibility: Visibility
    public var columnIndex: Int
    public var row: Int
    /// True for the active window of the focused column.
    public var isFocused: Bool

    public init(window: WindowID, frame: CGRect, visibility: Visibility, columnIndex: Int, row: Int, isFocused: Bool) {
        self.window = window
        self.frame = frame
        self.visibility = visibility
        self.columnIndex = columnIndex
        self.row = row
        self.isFocused = isFocused
    }
}

/// Everything about the display a strip is laid out on.
public struct LayoutContext: Equatable, Sendable {
    /// Working area: the display's visible frame (minus menu bar and Dock) inset by
    /// `outerGap` — see `LayoutEngine.workingArea`. AX space.
    public var area: CGRect
    /// The display's full frame. AX space.
    public var screenFrame: CGRect
    /// Full frames of every other display (used to keep parked/partial windows from
    /// spilling onto a neighbour). AX space.
    public var otherScreens: [CGRect]

    public init(area: CGRect, screenFrame: CGRect, otherScreens: [CGRect] = []) {
        self.area = area
        self.screenFrame = screenFrame
        self.otherScreens = otherScreens
    }

    /// Sides of `screenFrame` that touch another display (a window overflowing that
    /// edge would show up on the neighbour).
    public var blockedSides: Set<Side> {
        var sides = Set<Side>()
        for other in otherScreens {
            let verticalOverlap = min(other.maxY, screenFrame.maxY) - max(other.minY, screenFrame.minY) > 0
            guard verticalOverlap else { continue }
            if abs(other.maxX - screenFrame.minX) < 2 || (other.minX < screenFrame.minX && other.maxX > screenFrame.minX) {
                sides.insert(.left)
            }
            if abs(other.minX - screenFrame.maxX) < 2 || (other.maxX > screenFrame.maxX && other.minX < screenFrame.maxX) {
                sides.insert(.right)
            }
        }
        return sides
    }
}

/// One planned frame change for a window.
public struct FrameTransition: Equatable, Sendable {
    /// If set, put the window here instantly before animating (e.g. move a parked
    /// window from its corner to just off the screen edge at the right height, so it
    /// slides in horizontally instead of flying diagonally).
    public var start: CGRect?
    /// Where the window animates to.
    public var target: CGRect
    /// If set, put the window here instantly once the animation settles (e.g. the
    /// parking corner for a window that just slid off-screen).
    public var final: CGRect?

    public init(start: CGRect? = nil, target: CGRect, final: CGRect? = nil) {
        self.start = start
        self.target = target
        self.final = final
    }

    /// The frame the window ends up at.
    public var settledFrame: CGRect { final ?? target }
}


extension LayoutConfig {
    /// Tolerant decoding: every missing or malformed field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LayoutConfig()
        self.init(
            gap: c.value(.gap, default: d.gap),
            outerGap: c.value(.outerGap, default: d.outerGap),
            centreMode: c.value(.centreMode, default: d.centreMode),
            widthPresets: c.value(.widthPresets, default: d.widthPresets),
            defaultWidthFraction: c.value(.defaultWidthFraction, default: d.defaultWidthFraction),
            widthStep: c.value(.widthStep, default: d.widthStep),
            heightStep: c.value(.heightStep, default: d.heightStep),
            minWidthFraction: c.value(.minWidthFraction, default: d.minWidthFraction),
            parkingSliver: c.value(.parkingSliver, default: d.parkingSliver),
            tabBarHeight: c.value(.tabBarHeight, default: d.tabBarHeight),
            wrapsAround: c.value(.wrapsAround, default: d.wrapsAround)
        )
    }
}
