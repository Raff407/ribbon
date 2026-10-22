import Foundation

/// What a window looked like when the session was saved, for matching it again after
/// its app (or the Mac) restarted and window ids changed.
public struct WindowSignature: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String?
    public var title: String

    public init(bundleID: String?, title: String) {
        self.bundleID = bundleID
        self.title = title
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var world: World
    public var signatures: [WindowID: WindowSignature]

    public init(version: Int = SessionSnapshot.currentVersion, world: World, signatures: [WindowID: WindowSignature]) {
        self.version = version
        self.world = world
        self.signatures = signatures
    }
}

public enum SessionRestorer {
    /// Rebuilds a World from a saved snapshot and the windows that exist now.
    ///
    /// Matching, per saved window id, in order (each pass runs over every saved window
    /// before the next pass starts, so exact id matches always win):
    /// 1. A live window with the same id whose bundle id equals the saved signature's
    ///    (ids survive a Ribbon restart, but not an app restart). Without a saved
    ///    signature the id alone is enough.
    /// 2. Otherwise an unclaimed live window with the same bundle id and exact title.
    /// 3. Otherwise an unclaimed live window with the same bundle id (first by id order)
    ///    — only when the saved bundle id is non-nil.
    /// Each live window is claimed at most once. Saved windows without a match are
    /// dropped (empty columns/strips removed, focus repaired). Live windows that matched
    /// nothing are NOT added — the engine tiles them as new windows afterwards.
    /// Floating ids are mapped the same way. Snapshots with an unknown `version` give an
    /// empty World.
    public static func restore(_ snapshot: SessionSnapshot, liveWindows: [WindowInfo]) -> World {
        guard snapshot.version == SessionSnapshot.currentVersion else { return World() }
        let mapping = matchWindows(snapshot, liveWindows: liveWindows)
        let pruned = snapshot.world.pruning { mapping[$0] != nil }
        var strips: [StripKey: Strip] = [:]
        for (key, strip) in pruned.strips {
            let columns = strip.columns.map { column -> Column in
                var c = column
                c.windows = column.windows.compactMap { mapping[$0] }
                return c
            }
            strips[key] = Strip(columns: columns, focusedColumnIndex: strip.focusedColumnIndex, viewportOffset: strip.viewportOffset)
        }
        return World(strips: strips, floating: Set(pruned.floating.compactMap { mapping[$0] }))
    }

    /// Builds a snapshot of `world`, recording a signature for every managed window
    /// found in `windows` (windows without info get no signature).
    public static func snapshot(of world: World, windows: [WindowID: WindowInfo]) -> SessionSnapshot {
        var signatures: [WindowID: WindowSignature] = [:]
        for id in world.allTiledWindows.union(world.floating) {
            if let info = windows[id] {
                signatures[id] = WindowSignature(bundleID: info.bundleID, title: info.title)
            }
        }
        return SessionSnapshot(world: world, signatures: signatures)
    }

    /// Saved id → live id.
    static func matchWindows(_ snapshot: SessionSnapshot, liveWindows: [WindowInfo]) -> [WindowID: WindowID] {
        let saved = savedWindowOrder(snapshot.world)
        let live = liveWindows.sorted { $0.id < $1.id }
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var mapping: [WindowID: WindowID] = [:]
        var claimed = Set<WindowID>()

        func claim(_ savedID: WindowID, _ liveID: WindowID) {
            mapping[savedID] = liveID
            claimed.insert(liveID)
        }

        for id in saved {
            guard let info = liveByID[id] else { continue }
            let signature = snapshot.signatures[id]
            if signature == nil || signature?.bundleID == info.bundleID { claim(id, id) }
        }
        for id in saved where mapping[id] == nil {
            guard let signature = snapshot.signatures[id] else { continue }
            let match = live.first {
                !claimed.contains($0.id) && $0.bundleID == signature.bundleID && $0.title == signature.title
            }
            if let match { claim(id, match.id) }
        }
        for id in saved where mapping[id] == nil {
            guard let bundleID = snapshot.signatures[id]?.bundleID else { continue }
            if let match = live.first(where: { !claimed.contains($0.id) && $0.bundleID == bundleID }) {
                claim(id, match.id)
            }
        }
        return mapping
    }

    /// Every saved window in a deterministic order: strips by key, columns left to right,
    /// rows top to bottom, then floating windows by id.
    static func savedWindowOrder(_ world: World) -> [WindowID] {
        let tiled = world.strips.keys.sorted().flatMap { world.strips[$0]?.allWindows ?? [] }
        return tiled + world.floating.sorted()
    }
}
