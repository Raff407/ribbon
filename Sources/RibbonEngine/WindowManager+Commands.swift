import CoreGraphics
import Foundation
import RibbonCore

// Commands from hotkeys, the URL scheme, the menu bar and the indicator.
extension WindowManager {
    public func perform(_ command: Command) {
        guard isEnabled else {
            switch command {
            case .toggleEnabled: setEnabled(true)
            case .openSettings: openSettingsHandler?()
            case .gatherWindows: gatherAllWindows()
            default: break
            }
            return
        }
        switch command {
        case .toggleFloat: toggleFloat()
        case .sendToNextDisplay: sendToNextDisplay()
        case .toggleEnabled: setEnabled(false)
        case .gatherWindows: gatherAllWindows()
        case .showIndicator: showIndicator()
        case .openSettings: openSettingsHandler?()
        default: performStripCommand(command)
        }
    }

    func performStripCommand(_ command: Command) {
        guard let (key, display) = activeStrip() else { return }
        let strip = world.strip(key)
        guard !strip.isEmpty else { return }
        defer { showIndicator() }
        // Focus is elsewhere (desktop, a floating window): the first focus command just
        // brings focus back to the strip.
        if case .focus = command, let current = strip.focusedWindow,
           focusedWindowID.map({ !strip.contains($0) }) ?? true {
            focus(current)
            relayout(animated: true)
            return
        }
        let area = workingArea(display)
        var next = strip.applying(command, area: area, config: layoutConfig)
        if command != .centreColumn {
            next = LayoutEngine.revealFocused(next, area: area, config: layoutConfig)
        }
        guard next != strip else { return }
        world = world.setting(next, for: key)
        let newFocus = next.focusedWindow
        let focusChanged = newFocus != nil && newFocus != focusedWindowID
        if let newFocus, focusChanged { focus(newFocus) }
        relayout(animated: true)
        if focusChanged, settings.behavior.mouseFollowsFocus, let id = newFocus,
           let frame = services.applier.expectedFrame(of: id) {
            services.input.warpMouse(to: frame.center)
        }
    }

    // MARK: Float

    func toggleFloat() {
        guard let id = focusedWindowID ?? services.windows.focusedWindow() else { return }
        if let key = world.key(containing: id) {
            let display = self.display(forKey: key) ?? mainDisplay
            let frame = services.applier.expectedFrame(of: id) ?? infos[id]?.frame
            world = world.floatingWindow(id)
            storeRevealed(world.strip(key), for: key)
            if let display, let frame {
                let visible = display.visibleFrame
                let size = CGSize(width: min(frame.width, visible.width * 0.9), height: min(frame.height, visible.height * 0.9))
                let centred = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                     width: size.width, height: size.height).roundedToPoints
                services.applier.apply([id: FrameTransition(target: centred)], animation: animationSpec)
            }
        } else {
            guard let info = services.windows.windowInfo(id) ?? infos[id],
                  WindowClassifier.classify(info, settings: settings, ownBundleID: ownBundleID) != .ignore,
                  let key = stripKey(for: info) ?? activeStrip()?.key else { return }
            infos[id] = info
            world = world.tiling(id, into: key, position: .afterFocused,
                                 widthFraction: settings.layout.defaultWidthFraction, focus: true)
            storeRevealed(world.strip(key), for: key)
            focusedWindowID = id
        }
        relayout(animated: true)
        stateChangeHandler?()
    }

    var animationSpec: AnimationSpec? {
        settings.animation.enabled ? AnimationSpec(spring: settings.animation.effectiveSpring) : nil
    }

    // MARK: Displays

    func sendToNextDisplay() {
        let targets = enabledDisplays
        guard targets.count > 1, let id = focusedWindowID, let key = world.key(containing: id),
              let index = targets.firstIndex(where: { $0.uuid == key.displayUUID }) else { return }
        let next = targets[(index + 1) % targets.count]
        let strip = world.strip(key)
        let width = strip.location(of: id).map { strip.columns[$0.column].widthFraction } ?? settings.layout.defaultWidthFraction
        let target = activeKey(for: next)
        world = world.tiling(id, into: target, position: .afterFocused, widthFraction: width, focus: true)
        storeRevealed(world.strip(key), for: key)
        storeRevealed(world.strip(target), for: target)
        focus(id)
        relayout(animated: true)
    }

    // MARK: Indicator

    func showIndicator(persistent: Bool? = nil) {
        guard settings.appearance.indicatorEnabled, let (key, display) = activeStrip() else { return }
        let strip = world.strip(key)
        guard !strip.isEmpty else {
            services.overlays.hideIndicator()
            return
        }
        let keep = persistent ?? modifierHeld
        indicatorShownPersistent = keep
        let model = indicatorModel(strip, display: display)
        let now = services.scheduler.now()
        if let last = lastIndicator, last.persistent == keep {
            // Same picture: only refresh the fade timer now and then. Only the scroll
            // position moved (a gesture): redraw at most ~20 times a second.
            let sameTiles = last.model.tiles == model.tiles && last.model.focusedIndex == model.focusedIndex
            if (last.model == model && now - last.at < 0.3) || (sameTiles && now - last.at < 0.05) { return }
        }
        lastIndicator = (model, keep, now)
        services.overlays.showIndicator(model, on: display, persistent: keep)
    }

    func indicatorModel(_ strip: Strip, display: DisplayInfo) -> IndicatorModel {
        let tiles = strip.columns.map { column -> IndicatorTile in
            let id = column.activeWindow ?? column.windows[0]
            let info = infos[id]
            return IndicatorTile(pid: info?.pid ?? 0, bundleID: info?.bundleID, appName: info?.appName ?? "",
                                 windowCount: column.windows.count, isPinned: column.pin != nil)
        }
        let area = workingArea(display)
        let total = LayoutEngine.stripWidth(strip, area: area, config: layoutConfig)
        let width = Double(LayoutEngine.scrollableArea(strip, area: area, config: layoutConfig).width)
        var range: ClosedRange<Double> = 0...1
        if total > width, total > 0 {
            let lower = min(max(strip.viewportOffset / total, 0), 1)
            let upper = min(max((strip.viewportOffset + width) / total, lower), 1)
            range = lower...upper
        }
        return IndicatorModel(tiles: tiles, focusedIndex: strip.focusedColumnIndex, visibleRange: range)
    }

    func modifierHoldChanged(_ held: Bool) {
        modifierHeld = held
        if !held && indicatorShownPersistent { showIndicator(persistent: false) }
    }

    func indicatorTileClicked(_ index: Int) {
        guard isEnabled, let (key, display) = activeStrip() else { return }
        let strip = world.strip(key)
        let next = LayoutEngine.revealFocused(strip.applying(.focusColumn(index + 1), area: workingArea(display), config: layoutConfig),
                                              area: workingArea(display), config: layoutConfig)
        world = world.setting(next, for: key)
        if let id = next.focusedWindow { focus(id) }
        relayout(animated: true)
        showIndicator()
    }

    func indicatorTileMoved(from: Int, to: Int) {
        guard isEnabled, let (key, _) = activeStrip() else { return }
        storeRevealed(world.strip(key).movingColumn(from: from, to: to), for: key)
        relayout(animated: true)
        showIndicator()
    }

    func tabClicked(_ id: WindowID) {
        guard isEnabled, let key = world.key(containing: id) else { return }
        world = world.setting(world.strip(key).focusing(id), for: key)
        focus(id)
        relayout(animated: true)
    }
}
