import CoreGraphics
import Foundation
import RibbonCore

// Turning WindowEvents into World changes.
extension WindowManager {
    func handle(_ event: WindowEvent) {
        guard isEnabled else { return }
        switch event {
        case .windowCreated(let info): windowCreated(info)
        case .windowDestroyed(let id): windowDestroyed(id)
        case .windowFocused(let id): windowFocused(id)
        case .windowMoved(let id, let frame), .windowResized(let id, let frame): windowFrameChanged(id, frame: frame)
        case .windowMinimized(let id): park(id, reason: .minimized)
        case .windowDeminimized(let id): unpark(id, focus: true, clearing: .minimized)
        case .windowTitleChanged(let id, let title): titleChanged(id, title: title)
        case .windowFullscreenChanged(let id, let isFullscreen): fullscreenChanged(id, isFullscreen: isFullscreen)
        case .appLaunched: break
        case .appTerminated(let pid): appTerminated(pid)
        case .appHidden(let pid): appHidden(pid)
        case .appShown(let pid): appShown(pid)
        case .appActivated:
            debounce("activate", 0.3) { [weak self] in self?.reconcile(relayoutIfChanged: true, onlyIfWindowsChanged: true) }
        case .spaceChanged: debounce("space", 0.2) { [weak self] in self?.spaceChanged() }
        case .systemWoke: debounce("wake", 1) { [weak self] in self?.systemWoke() }
        }
    }

    // MARK: Creation / destruction

    func windowCreated(_ info: WindowInfo) {
        infos[info.id] = info
        guard !world.isManaged(info.id), tabGroups[info.id] == nil, !pendingTabChecks.contains(info.id) else { return }
        if beginNativeTabCheck(info) { return }
        let focused = focusedWindowID == info.id || services.windows.focusedWindow() == info.id
        if adopt(info, focus: focused) {
            if focused { focusedWindowID = info.id }
            relayout(animated: true)
            stateChangeHandler?()
        }
    }

    /// Tiles or floats a window Ribbon doesn't manage yet. Returns true if it changed the world.
    @discardableResult
    func adopt(_ info: WindowInfo, focus: Bool, position: InsertPosition? = nil) -> Bool {
        switch WindowClassifier.classify(info, settings: settings, ownBundleID: ownBundleID) {
        case .ignore:
            return false
        case .float:
            world = world.floatingWindow(info.id)
            return true
        case .tile:
            guard let key = stripKey(for: info) else { return false }
            let insertAt = position ?? (settings.behavior.newWindowPosition == .end ? .end : .afterFocused)
            world = world.tiling(info.id, into: key, position: insertAt,
                                 widthFraction: settings.layout.defaultWidthFraction, focus: focus)
            if focus { storeRevealed(world.strip(key), for: key) }
            return true
        }
    }

    func windowDestroyed(_ id: WindowID) {
        forgetWindowState(id)
        defer { infos[id] = nil }
        if let sibling = leaveTabGroup(id), let key = world.key(containing: id) {
            world = world.setting(world.strip(key).replacing(id, with: sibling), for: key)
            if focusedWindowID == id { focusedWindowID = sibling }
            relayout(animated: true)
            return
        }
        let key = world.key(containing: id)
        let wasFocused = focusedWindowID == id || key.map { world.strip($0).focusedWindow == id } ?? false
        guard world.isManaged(id) else { return }
        world = world.removing(id)
        if focusedWindowID == id { focusedWindowID = nil }
        if let key {
            storeRevealed(world.strip(key), for: key)
            if wasFocused, isActiveKey(key), let next = world.strip(key).focusedWindow {
                debounce("close-focus-\(id)", 0.05) { [weak self] in
                    guard let self, self.isEnabled, self.isActiveKey(key),
                          self.world.strip(key).focusedWindow == next else { return }
                    self.focus(next)
                    self.relayout(animated: true)
                }
            }
        }
        relayout(animated: true)
        stateChangeHandler?()
    }

    func appTerminated(_ pid: ProcessID) {
        let windows = infos.values.filter { $0.pid == pid }.map(\.id)
        guard !windows.isEmpty else { return }
        for id in windows {
            forgetWindowState(id)
            _ = leaveTabGroup(id)
            infos[id] = nil
            world = world.removing(id)
            if focusedWindowID == id { focusedWindowID = nil }
        }
        revealAllActiveStrips()
        relayout(animated: true)
        stateChangeHandler?()
    }

    /// Release both delayed work and per-window caches on every removal path.
    func forgetWindowState(_ id: WindowID) {
        services.applier.forget(id)
        restoreHints[id] = nil
        pendingTabChecks.remove(id)
        lastLayoutTime[id] = nil
        widthAdoptions[id] = nil
        for name in ["native-tab-\(id)", "fullscreen-\(id)", "app-move-\(id)", "close-focus-\(id)"] {
            debounces.removeValue(forKey: name)?.cancel()
        }
        if pendingFocus?.window == id { pendingFocus = nil }
        if suppressRevealFor == id { suppressRevealFor = nil }
        if draggedWindow == id { draggedWindow = nil }
    }

    // MARK: Focus

    func windowFocused(_ id: WindowID) {
        let now = services.scheduler.now()
        if let pending = pendingFocus {
            if pending.window != id && now < pending.until { return }
            pendingFocus = nil
        }
        focusedWindowID = id
        let suppressReveal = suppressRevealFor == id
        suppressRevealFor = nil
        if world.key(containing: id) == nil, let group = tabGroups[id],
           let shown = group.first(where: { world.key(containing: $0) != nil }), let key = world.key(containing: shown) {
            world = world.setting(world.strip(key).replacing(shown, with: id), for: key)
        }
        if let key = world.key(containing: id) {
            let strip = world.strip(key).focusing(id)
            if suppressReveal {
                world = world.setting(strip, for: key)
            } else {
                storeRevealed(strip, for: key)
            }
            relayout(animated: true)
        } else if world.floating.contains(id) {
            relayout(animated: true)
        } else if let info = services.windows.windowInfo(id) {
            windowCreated(info)
        }
    }

    /// Focuses `id` and ignores stale focus events for other windows for a moment.
    func focus(_ id: WindowID) {
        pendingFocus = (id, services.scheduler.now() + Self.pendingFocusWindow)
        focusedWindowID = id
        services.windows.focus(id)
    }

    // MARK: Moves and resizes

    func windowFrameChanged(_ id: WindowID, frame: CGRect) {
        guard world.key(containing: id) != nil else { return }
        infos[id]?.frame = frame
        guard !isOwnMove(id, frame: frame) else { return }
        if services.input.isLeftMouseDown {
            draggedWindow = id
            return
        }
        debounce("app-move-\(id)", 0.25) { [weak self] in self?.appMovedWindow(id) }
    }

    func isOwnMove(_ id: WindowID, frame: CGRect) -> Bool {
        if services.applier.isAnimating { return true }
        if let last = lastLayoutTime[id], services.scheduler.now() - last < Self.ownMoveWindow { return true }
        return services.applier.expectedFrame(of: id)?.isApproximatelyEqual(to: frame, tolerance: Self.ownMoveTolerance) ?? false
    }

    /// The app moved/resized its own window: adopt an enforced width (once in a while),
    /// otherwise snap it back.
    func appMovedWindow(_ id: WindowID) {
        guard let key = world.key(containing: id), let display = display(forKey: key) else { return }
        if let frame = services.windows.frame(of: id), let expected = services.applier.expectedFrame(of: id),
           abs(frame.width - expected.width) > Self.ownMoveTolerance {
            let now = services.scheduler.now()
            if now - (widthAdoptions[id] ?? -.infinity) >= Self.widthAdoptionInterval {
                widthAdoptions[id] = now
                adoptWidth(frame.width, of: id, key: key, display: display)
            }
        }
        relayout(animated: true, force: true)
    }

    func adoptWidth(_ width: CGFloat, of id: WindowID, key: StripKey, display: DisplayInfo) {
        let gap = settings.layout.gap
        let fraction = (Double(width) + gap) / (Double(workingArea(display).width) + gap)
        let strip = world.strip(key).settingWidthFraction(fraction, ofColumnContaining: id, config: settings.layout)
        world = world.setting(strip, for: key)
    }

    // MARK: Minimize / fullscreen / hide

    enum ParkReason { case minimized, fullscreen, hidden }

    /// Takes a window off its strip temporarily, remembering where it was.
    func park(_ id: WindowID, reason: ParkReason, relayoutAfter: Bool = true) {
        if reason == .minimized { infos[id]?.isMinimized = true }
        parkSequence += 1
        if let key = world.key(containing: id), let loc = world.strip(key).location(of: id) {
            restoreHints[id] = RestoreHint(key: key, column: loc.column, wasFloating: false, sequence: parkSequence)
        } else if world.floating.contains(id) {
            restoreHints[id] = RestoreHint(key: StripKey(displayUUID: "", spaceID: 0), column: 0, wasFloating: true, sequence: parkSequence)
        } else {
            return
        }
        world = world.removing(id)
        if focusedWindowID == id { focusedWindowID = nil }
        if relayoutAfter {
            revealAllActiveStrips()
            relayout(animated: true)
        }
    }

    /// Puts a parked window back where it was (or treats it as new).
    func unpark(_ id: WindowID, focus: Bool, relayoutAfter: Bool = true, clearing reason: ParkReason? = nil) {
        guard isEnabled, !world.isManaged(id), var info = services.windows.windowInfo(id) ?? infos[id] else { return }
        // The event clears only its own state; showing an app must not unminimize it.
        switch reason {
        case .minimized: info.isMinimized = false
        case .fullscreen: info.isFullscreen = false
        case .hidden: info.isAppHidden = false
        case nil: break
        }
        infos[id] = info
        guard !info.isMinimized, !info.isFullscreen, !info.isAppHidden else { return }
        let hint = restoreHints.removeValue(forKey: id)
        if let hint, hint.wasFloating {
            world = world.floatingWindow(id)
        } else if let hint, isEnabledDisplay(hint.key.displayUUID) {
            world = world.tiling(id, into: hint.key, position: .at(hint.column),
                                 widthFraction: settings.layout.defaultWidthFraction, focus: focus)
            if focus { storeRevealed(world.strip(hint.key), for: hint.key) }
        } else {
            adopt(info, focus: focus)
        }
        if focus { focusedWindowID = id }
        if relayoutAfter { relayout(animated: true) }
    }

    func fullscreenChanged(_ id: WindowID, isFullscreen: Bool) {
        infos[id]?.isFullscreen = isFullscreen
        debounces.removeValue(forKey: "fullscreen-\(id)")?.cancel()
        if isFullscreen {
            park(id, reason: .fullscreen)
        } else if restoreHints[id] != nil {
            debounce("fullscreen-\(id)", 0.5) { [weak self] in
                guard let self, self.infos[id]?.isFullscreen == false, self.restoreHints[id] != nil else { return }
                self.unpark(id, focus: true, clearing: .fullscreen)
            }
        }
    }

    func appHidden(_ pid: ProcessID) {
        // Mark every window of the app, including ones already off the strip (minimized,
        // fullscreen), so they wait for the app to come back even if AX can't be read.
        for id in infos.keys where infos[id]?.pid == pid { infos[id]?.isAppHidden = true }
        let windows = infos.values.filter { $0.pid == pid && world.isManaged($0.id) }.map(\.id)
        guard !windows.isEmpty else { return }
        windows.forEach { park($0, reason: .hidden, relayoutAfter: false) }
        revealAllActiveStrips()
        relayout(animated: true)
    }

    func appShown(_ pid: ProcessID) {
        for id in infos.keys where infos[id]?.pid == pid && restoreHints[id] == nil { infos[id]?.isAppHidden = false }
        let windows = restoreHints.filter { infos[$0.key]?.pid == pid }
            .sorted { $0.value.sequence > $1.value.sequence }.map(\.key)
        guard !windows.isEmpty else { return }
        windows.forEach { unpark($0, focus: false, relayoutAfter: false, clearing: .hidden) }
        relayout(animated: true)
    }

    func titleChanged(_ id: WindowID, title: String) {
        infos[id]?.title = title
        if let key = world.key(containing: id), let loc = world.strip(key).location(of: id),
           world.strip(key).columns[loc.column].mode == .tabbed {
            relayout(animated: false)
        } else {
            scheduleSave()
        }
    }

    // MARK: Spaces / wake

    func spaceChanged() {
        guard isEnabled else { return }
        reconcile(relayoutIfChanged: false)
        revealAllActiveStrips()
        relayout(animated: false)
    }

    func systemWoke() {
        guard isEnabled else { return }
        refreshDisplays()
        reconcile(relayoutIfChanged: false)
        revealAllActiveStrips()
        relayout(animated: false, force: true)
    }
}
