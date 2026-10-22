import ApplicationServices
import Foundation
import RibbonCore

/// Every window element `AXWindowSource` knows about, keyed both ways, plus the
/// lifecycle state that guarantees `.windowCreated` is emitted at most once per id.
///
/// Immutable value type: every change returns a new registry.
struct WindowRegistry {
    enum Phase: Equatable {
        /// `.windowCreated` is scheduled (waiting for the window's attributes to settle).
        case pending
        /// The engine knows the window (emitted as created, or returned by a query).
        case announced
    }

    private(set) var elements: [WindowID: AXUIElement] = [:]
    /// Reverse map: destroyed elements can't be asked for their id any more.
    private(set) var ids: [AXElementKey: WindowID] = [:]
    private(set) var owners: [WindowID: pid_t] = [:]
    /// Absent = registered but never announced (e.g. creation gave up).
    private(set) var phases: [WindowID: Phase] = [:]
    /// Last reported `AXFullScreen`, to emit `.windowFullscreenChanged` only on flips.
    private(set) var fullscreen: [WindowID: Bool] = [:]
    /// Pending windows that were focused before `.windowCreated` went out.
    private(set) var focusAfterCreation: Set<WindowID> = []

    // MARK: Queries

    func element(for id: WindowID) -> AXUIElement? { elements[id] }
    func id(for element: AXUIElement) -> WindowID? { ids[AXElementKey(element)] }
    func pid(of id: WindowID) -> pid_t? { owners[id] }
    func phase(of id: WindowID) -> Phase? { phases[id] }
    func isFullscreen(_ id: WindowID) -> Bool { fullscreen[id] ?? false }
    func contains(_ id: WindowID) -> Bool { elements[id] != nil }

    func windows(of pid: pid_t) -> [WindowID] {
        owners.filter { $0.value == pid }.map(\.key)
    }

    /// The id of `element` if the engine already knows the window.
    func announcedID(for element: AXUIElement) -> WindowID? {
        guard let id = id(for: element), phases[id] == .announced else { return nil }
        return id
    }

    // MARK: Updates (each returns a new registry)

    /// Adds or refreshes the element for `id` (replacing a stale, non-equal element).
    func registering(_ id: WindowID, element: AXUIElement, pid: pid_t) -> WindowRegistry {
        var next = self
        if let old = elements[id] {
            next.ids.removeValue(forKey: AXElementKey(old))
        }
        next.elements[id] = element
        next.ids[AXElementKey(element)] = id
        next.owners[id] = pid
        return next
    }

    func settingPhase(_ phase: Phase?, for id: WindowID) -> WindowRegistry {
        guard contains(id) else { return self }
        var next = self
        next.phases[id] = phase
        if phase != .pending {
            next.focusAfterCreation.remove(id)
        }
        return next
    }

    func settingFullscreen(_ value: Bool, for id: WindowID) -> WindowRegistry {
        guard contains(id) else { return self }
        var next = self
        next.fullscreen[id] = value
        return next
    }

    func requestingFocusAfterCreation(_ id: WindowID) -> WindowRegistry {
        guard phases[id] == .pending else { return self }
        var next = self
        next.focusAfterCreation.insert(id)
        return next
    }

    func removing(_ id: WindowID) -> WindowRegistry {
        var next = self
        if let element = next.elements.removeValue(forKey: id) {
            next.ids.removeValue(forKey: AXElementKey(element))
        }
        next.owners.removeValue(forKey: id)
        next.phases.removeValue(forKey: id)
        next.fullscreen.removeValue(forKey: id)
        next.focusAfterCreation.remove(id)
        return next
    }

    func removingAll(of pid: pid_t) -> WindowRegistry {
        windows(of: pid).reduce(self) { $0.removing($1) }
    }
}

/// What to do with a pending window after (re)reading its attributes. Pure.
enum CreationPolicy {
    enum Step: Equatable {
        case emit
        case retry(after: TimeInterval)
        /// Unreadable even after the retries: leave it for the next reconcile.
        case giveUp
    }

    /// First read happens this long after `kAXWindowCreatedNotification`.
    static let settleDelay: TimeInterval = 0.05
    static let retryDelay: TimeInterval = 0.15
    /// Retries after the first read while the subrole is unresolved.
    static let maxRetries = 3

    /// `attempt` 0 is the first read. Unresolved subrole (nil/"AXUnknown") or unreadable
    /// attributes retry up to `maxRetries` times; then an unresolved subrole is emitted
    /// anyway and an unreadable window is given up.
    static func step(for attributes: WindowAttributes?, attempt: Int) -> Step {
        let canRetry = attempt < maxRetries
        guard let attributes, attributes.frame != nil else {
            return canRetry ? .retry(after: retryDelay) : .giveUp
        }
        if attributes.isSubroleUnresolved && canRetry {
            return .retry(after: retryDelay)
        }
        return .emit
    }
}
