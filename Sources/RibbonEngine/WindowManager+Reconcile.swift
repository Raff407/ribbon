import CoreGraphics
import Foundation
import RibbonCore

// Initial scan, periodic consistency sweeps, native tabs and reclassification.
extension WindowManager {
    func initialScan() {
        displays = services.screens.displays()
        let live = services.windows.currentWindows()
        infos = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if settings.behavior.restoreSession, let snapshot = services.sessionStore.load() {
            world = rekeyed(SessionRestorer.restore(snapshot, liveWindows: live))
            world = world.pruning { id in
                guard let info = infos[id] else { return false }
                return WindowClassifier.classify(info, settings: settings, ownBundleID: ownBundleID) != .ignore
                    && (world.floating.contains(id) || stripKey(for: info) != nil)
            }
        }
        adoptUnknown(live, onScreen: services.windows.onScreenWindowIDs())
        lastReconcileWindowSet = services.windows.existingWindowIDs()
        focusedWindowID = services.windows.focusedWindow()
        if let focused = focusedWindowID, let key = world.key(containing: focused) {
            world = world.setting(world.strip(key).focusing(focused), for: key)
        }
        revealAllActiveStrips()
        relayout(animated: false, force: true)
    }

    /// Restored strips whose saved Space/display no longer matches where their windows
    /// actually are get merged into the right strip (Space ids change across logins).
    func rekeyed(_ restored: World) -> World {
        var result = restored
        for (key, strip) in restored.strips {
            let actual = strip.allWindows.compactMap { infos[$0].flatMap(stripKey(for:)) }
            let counts = Dictionary(actual.map { ($0, 1) }, uniquingKeysWith: +)
            guard let best = counts.max(by: { $0.value < $1.value })?.key, best != key else { continue }
            result = result.mergingStrip(key, into: best)
        }
        return result
    }

    /// Tiles (in on-screen left-to-right order) or floats every live window Ribbon doesn't
    /// manage yet, detecting native tab groups on the way. Returns true if anything changed.
    @discardableResult
    func adoptUnknown(_ live: [WindowInfo], onScreen: Set<WindowID>) -> Bool {
        var changed = false
        for info in live.sorted(by: { ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id) }) {
            guard !world.isManaged(info.id), tabGroups[info.id] == nil, restoreHints[info.id] == nil,
                  !pendingTabChecks.contains(info.id) else { continue }
            if resolveNativeTab(info, onScreen: onScreen) {
                changed = true
                continue
            }
            changed = adopt(info, focus: false, position: .end) || changed
        }
        return changed
    }

    /// Brings the world in line with the windows that exist. With `onlyIfWindowsChanged`
    /// (periodic sweeps, app switches) the Accessibility scan — several IPC round trips per
    /// window of every app — is skipped while the window server's window set is unchanged.
    func reconcile(relayoutIfChanged: Bool, onlyIfWindowsChanged: Bool = false) {
        guard isEnabled else { return }
        let existing = services.windows.existingWindowIDs()
        if onlyIfWindowsChanged, !existing.isEmpty, existing == lastReconcileWindowSet { return }
        lastReconcileWindowSet = existing.isEmpty ? nil : existing
        let live = services.windows.currentWindows()
        let before = world
        for info in live { infos[info.id] = info }
        if !existing.isEmpty {
            world = world.pruning { existing.contains($0) }
            for id in Array(infos.keys) where !existing.contains(id) {
                infos[id] = nil
                forgetWindowState(id)
                _ = leaveTabGroup(id)
            }
            if let focused = focusedWindowID, !existing.contains(focused) { focusedWindowID = nil }
        }
        for info in live where world.isManaged(info.id) {
            if info.isMinimized { park(info.id, reason: .minimized, relayoutAfter: false) }
            else if info.isFullscreen { park(info.id, reason: .fullscreen, relayoutAfter: false) }
            else if info.isAppHidden { park(info.id, reason: .hidden, relayoutAfter: false) }
        }
        let returning = live.filter { restoreHints[$0.id] != nil && !$0.isMinimized && !$0.isFullscreen && !$0.isAppHidden }
        for info in returning.sorted(by: { (restoreHints[$0.id]?.sequence ?? 0) > (restoreHints[$1.id]?.sequence ?? 0) }) {
            unpark(info.id, focus: false, relayoutAfter: false)
        }
        adoptUnknown(live, onScreen: services.windows.onScreenWindowIDs())
        guard world != before else { return }
        revealAllActiveStrips()
        stateChangeHandler?()
        if relayoutIfChanged { relayout(animated: true) }
    }

    // MARK: Native tabs

    /// A managed window of the same app with (almost) the same frame — a native tab sibling.
    func tabHost(for info: WindowInfo) -> WindowID? {
        guard WindowClassifier.classify(info, settings: settings, ownBundleID: ownBundleID) == .tile else { return nil }
        return world.allTiledWindows.sorted().first { id in
            guard id != info.id, let other = infos[id], other.pid == info.pid else { return false }
            let frame = services.applier.expectedFrame(of: id) ?? other.frame
            return frame.isApproximatelyEqual(to: info.frame, tolerance: 2)
        }
    }

    /// For a freshly created window: if it might be a new native tab, check again once the
    /// window server has updated (0.15 s) instead of tiling it right away.
    func beginNativeTabCheck(_ info: WindowInfo) -> Bool {
        guard let host = tabHost(for: info) else { return false }
        pendingTabChecks.insert(info.id)
        debounce("native-tab-\(info.id)", 0.15) { [weak self] in
            guard let self else { return }
            self.pendingTabChecks.remove(info.id)
            guard self.isEnabled, !self.world.isManaged(info.id), self.infos[info.id] != nil else { return }
            let onScreen = self.services.windows.onScreenWindowIDs()
            if !self.resolveNativeTab(info, onScreen: onScreen, host: host) {
                self.adopt(info, focus: self.focusedWindowID == info.id)
            }
            self.relayout(animated: true)
            self.stateChangeHandler?()
        }
        return true
    }

    /// Groups `info` with its host when exactly one of the two is on screen (inactive native
    /// tabs aren't). The on-screen one is the one on the strip. Returns true when grouped.
    @discardableResult
    func resolveNativeTab(_ info: WindowInfo, onScreen: Set<WindowID>, host knownHost: WindowID? = nil) -> Bool {
        guard let host = knownHost ?? tabHost(for: info), let key = world.key(containing: host) else { return false }
        let newVisible = onScreen.contains(info.id)
        let hostVisible = onScreen.contains(host)
        guard newVisible != hostVisible else { return false }
        joinTabGroup(info.id, with: host)
        if newVisible {
            world = world.setting(world.strip(key).replacing(host, with: info.id), for: key)
            if focusedWindowID == host { focusedWindowID = info.id }
        }
        return true
    }

    func joinTabGroup(_ id: WindowID, with host: WindowID) {
        let group = (tabGroups[host] ?? [host]).union([id])
        for member in group { tabGroups[member] = group }
    }

    /// Removes `id` from its tab group; returns a surviving member to take its place on
    /// the strip (nil when it had no group).
    func leaveTabGroup(_ id: WindowID) -> WindowID? {
        guard let group = tabGroups.removeValue(forKey: id) else { return nil }
        let rest = group.subtracting([id])
        for member in rest { tabGroups[member] = rest.count > 1 ? rest : nil }
        let onScreen = services.windows.onScreenWindowIDs()
        return rest.sorted().first { onScreen.contains($0) } ?? rest.sorted().first
    }

    // MARK: Settings changes

    func reclassifyManagedWindows() {
        for id in world.allTiledWindows.union(world.floating) {
            guard let info = infos[id] else { continue }
            let disposition = WindowClassifier.classify(info, settings: settings, ownBundleID: ownBundleID)
            let isFloating = world.floating.contains(id)
            switch disposition {
            case .ignore:
                world = world.removing(id)
            case .float where !isFloating:
                world = world.floatingWindow(id)
            case .tile where isFloating:
                world = world.removing(id)
                adopt(info, focus: false)
            default:
                break
            }
        }
    }

    /// Un-parks and forgets the windows on displays that were just disabled.
    func releaseDisabledDisplays() {
        let disabled = Set(settings.disabledDisplays)
        let keys = world.strips.keys.filter { disabled.contains($0.displayUUID) }
        guard !keys.isEmpty else { return }
        let released = World(strips: world.strips.filter { keys.contains($0.key) })
        let kept = world
        world = released
        unparkAll()
        world = kept
        for key in keys { world = world.setting(Strip(), for: key) }
    }
}
