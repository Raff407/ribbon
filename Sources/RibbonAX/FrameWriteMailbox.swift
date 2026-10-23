import Foundation
import RibbonCore

/// A pending frame operation. A later position preserves an unapplied resize; a later
/// resize preserves the latest position. Full frames replace both when necessary.
struct FrameWrite: Equatable {
    var position: CGPoint?
    var size: CGSize?

    func merging(_ later: FrameWrite) -> FrameWrite {
        FrameWrite(position: later.position ?? position, size: later.size ?? size)
    }
}

/// At most one waiting operation per window, in addition to any AX call already running.
/// The token prevents a callback queued before `remove` from consuming a new window's
/// update if its window-server id is reused.
final class FrameWriteMailbox {
    private struct Entry {
        var token: UInt64
        var write: FrameWrite
    }

    private let lock = NSLock()
    private var entries: [WindowID: Entry] = [:]
    private var nextToken: UInt64 = 0

    /// Returns a token only when the caller needs to enqueue a consumer.
    func submit(_ write: FrameWrite, for id: WindowID) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        if var entry = entries[id] {
            entry.write = entry.write.merging(write)
            entries[id] = entry
            return nil
        }
        nextToken &+= 1
        entries[id] = Entry(token: nextToken, write: write)
        return nextToken
    }

    func take(for id: WindowID, token: UInt64) -> FrameWrite? {
        lock.lock()
        defer { lock.unlock() }
        guard entries[id]?.token == token else { return nil }
        return entries.removeValue(forKey: id)?.write
    }

    func remove(_ id: WindowID) {
        lock.lock()
        entries[id] = nil
        lock.unlock()
    }
}
