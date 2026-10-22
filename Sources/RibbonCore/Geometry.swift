import CoreGraphics
import Foundation

/// A macOS window server id (CGWindowID). Stable for the lifetime of the window.
public typealias WindowID = UInt32

/// A process id.
public typealias ProcessID = Int32

public enum Side: String, Codable, CaseIterable, Sendable {
    case left, right

    public var opposite: Side { self == .left ? .right : .left }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case left, right, up, down
}

/// Coordinate conventions used across Ribbon:
///
/// * **AX space** (the default everywhere in RibbonCore and RibbonEngine): global
///   coordinates with the origin at the top-left of the primary display (the one
///   with the menu bar, `NSScreen.screens[0]`), y growing downwards. This is what
///   the Accessibility API uses for `kAXPositionAttribute`.
/// * **Cocoa space**: origin at the bottom-left of the primary display, y growing
///   upwards. Used by `NSScreen`/`NSWindow`.
///
/// The conversion is symmetric, so one function goes both ways.
public enum CoordinateSpace {
    /// Converts a rect between AX space and Cocoa space (the mapping is its own inverse).
    /// - Parameter primaryHeight: height of the primary display's full frame.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a point between AX space and Cocoa space.
    public static func flip(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

public extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// True when every edge is within `tolerance` points of `other`'s.
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    /// Area of the intersection with `other` (0 when disjoint).
    func intersectionArea(with other: CGRect) -> CGFloat {
        let i = intersection(other)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Returns a copy rounded to whole points (AX positions are integral in practice).
    var roundedToPoints: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}
