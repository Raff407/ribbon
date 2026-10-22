import Foundation

/// Identifies one strip: a display (by UUID) and a Space on it.
public struct StripKey: Hashable, Codable, Comparable, CustomStringConvertible, Sendable {
    public var displayUUID: String
    /// 0 when Spaces are unknown.
    public var spaceID: UInt64

    public init(displayUUID: String, spaceID: UInt64) {
        self.displayUUID = displayUUID
        self.spaceID = spaceID
    }

    public var description: String { "\(displayUUID)#\(spaceID)" }

    public static func < (lhs: StripKey, rhs: StripKey) -> Bool {
        (lhs.displayUUID, lhs.spaceID) < (rhs.displayUUID, rhs.spaceID)
    }
}

/// Everything Ribbon manages: one strip per (display, Space) plus floating windows.
///
/// Invariant: a window is in at most one strip, and never both in a strip and in
/// `floating`. Every operation is pure and returns a new World.
public struct World: Equatable, Codable, Sendable {
    public var strips: [StripKey: Strip]
    public var floating: Set<WindowID>

    public init(strips: [StripKey: Strip] = [:], floating: Set<WindowID> = []) {
        self.strips = strips
        self.floating = floating
    }

    /// The strip for `key`, or an empty strip.
    public func strip(_ key: StripKey) -> Strip {
        strips[key] ?? Strip()
    }

    /// The key of the strip containing `window`, if tiled.
    public func key(containing window: WindowID) -> StripKey? {
        strips.first { $0.value.contains(window) }?.key
    }

    public func isManaged(_ window: WindowID) -> Bool {
        floating.contains(window) || key(containing: window) != nil
    }

    public var allTiledWindows: Set<WindowID> {
        Set(strips.values.flatMap(\.allWindows))
    }

    /// Returns a world with `strip` stored at `key` (empty strips are removed from
    /// `strips` entirely, to keep persistence small).
    public func setting(_ strip: Strip, for key: StripKey) -> World {
        var newStrips = strips
        newStrips[key] = strip.isEmpty ? nil : strip
        return World(strips: newStrips, floating: floating)
    }

    /// Removes `window` from wherever it is (any strip or floating).
    public func removing(_ window: WindowID) -> World {
        var newFloating = floating
        newFloating.remove(window)
        let base = World(strips: strips, floating: newFloating)
        guard let key = key(containing: window) else { return base }
        return base.setting(strip(key).removing(window), for: key)
    }

    /// Tiles `window` into the strip at `key` (removing it from anywhere else first).
    public func tiling(_ window: WindowID, into key: StripKey, position: InsertPosition, widthFraction: Double, focus: Bool) -> World {
        let base = removing(window)
        let strip = base.strip(key).inserting(window, position: position, widthFraction: widthFraction, focus: focus)
        return base.setting(strip, for: key)
    }

    /// Marks `window` floating (removing it from any strip first).
    public func floatingWindow(_ window: WindowID) -> World {
        let base = removing(window)
        return World(strips: base.strips, floating: base.floating.union([window]))
    }

    /// Moves every column of the strip at `from` to the end of the strip at `to`
    /// (pins are dropped from the moved columns; the target's focus is unchanged unless
    /// it was empty, in which case it focuses the first moved column). Used when a
    /// display disappears.
    public func mergingStrip(_ from: StripKey, into to: StripKey) -> World {
        guard from != to, let source = strips[from], !source.isEmpty else { return self }
        let target = strip(to)
        let moved = source.columns.map { column -> Column in
            var c = column
            c.pin = nil
            return c
        }
        var columns = target.columns
        let insertAt = target.rightPinnedColumnIndex ?? columns.count
        columns.insert(contentsOf: moved, at: insertAt)
        let focus: Int? = target.focusedColumnIndex.map { $0 >= insertAt ? $0 + moved.count : $0 } ?? 0
        let merged = Strip(columns: columns, focusedColumnIndex: focus, viewportOffset: target.viewportOffset)
        var newStrips = strips
        newStrips[from] = nil
        newStrips[to] = merged
        return World(strips: newStrips, floating: floating)
    }

    /// Keeps only the windows for which `isAlive` returns true; empty columns/strips are
    /// dropped and focus is repaired (as in `Strip.removing`).
    public func pruning(keeping isAlive: (WindowID) -> Bool) -> World {
        var result = World(strips: strips, floating: floating.filter(isAlive))
        for (key, strip) in strips {
            let dead = strip.allWindows.filter { !isAlive($0) }
            guard !dead.isEmpty else { continue }
            result = result.setting(dead.reduce(strip) { $0.removing($1) }, for: key)
        }
        return result
    }
}
