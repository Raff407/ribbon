import CoreGraphics
import Foundation
import RibbonCore

// Displays, strip keys and pushing frames to the applier.
extension WindowManager {
    /// Layout config with engine-side overrides (no tab bar space when tab bars are off).
    var layoutConfig: LayoutConfig {
        var config = settings.layout
        if !settings.appearance.tabBarsEnabled { config.tabBarHeight = 0 }
        return config
    }

    var enabledDisplays: [DisplayInfo] {
        displays.filter { !settings.disabledDisplays.contains($0.uuid) }
    }

    var mainDisplay: DisplayInfo? { displays.first(where: \.isMain) ?? displays.first }

    func isEnabledDisplay(_ uuid: String) -> Bool {
        !settings.disabledDisplays.contains(uuid) && displays.contains { $0.uuid == uuid }
    }

    /// The strip shown on `display` right now.
    func activeKey(for display: DisplayInfo) -> StripKey {
        StripKey(displayUUID: display.uuid, spaceID: services.spaces.currentSpace(forDisplayUUID: display.uuid))
    }

    func isActiveKey(_ key: StripKey) -> Bool {
        guard let display = display(forKey: key) else { return false }
        return activeKey(for: display) == key
    }

    func display(forKey key: StripKey) -> DisplayInfo? {
        displays.first { $0.uuid == key.displayUUID }
    }

    /// Display containing the rect's centre, else the one it overlaps most, else main.
    func display(for frame: CGRect) -> DisplayInfo? {
        if let containing = displays.first(where: { $0.frame.contains(frame.center) }) { return containing }
        let best = displays.max { $0.frame.intersectionArea(with: frame) < $1.frame.intersectionArea(with: frame) }
        if let best, best.frame.intersectionArea(with: frame) > 0 { return best }
        return mainDisplay
    }

    func display(containing point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    /// Where a window that isn't managed yet belongs; nil on a disabled display.
    func stripKey(for info: WindowInfo) -> StripKey? {
        guard let display = display(for: info.frame), isEnabledDisplay(display.uuid) else { return nil }
        let space = services.spaces.spaces(for: [info.id])[info.id] ?? services.spaces.currentSpace(forDisplayUUID: display.uuid)
        return StripKey(displayUUID: display.uuid, spaceID: space)
    }

    func workingArea(_ display: DisplayInfo) -> CGRect {
        LayoutEngine.workingArea(visibleFrame: display.visibleFrame, config: layoutConfig)
    }

    func layoutContext(_ display: DisplayInfo) -> LayoutContext {
        LayoutContext(area: workingArea(display), screenFrame: display.frame,
                      otherScreens: displays.filter { $0.uuid != display.uuid }.map(\.frame))
    }

    /// The strip commands act on: the one holding the focused window, else the one under
    /// the mouse, else the main display's.
    func activeStrip() -> (key: StripKey, display: DisplayInfo)? {
        if let focused = focusedWindowID, let key = world.key(containing: focused), isActiveKey(key),
           let display = display(forKey: key), isEnabledDisplay(display.uuid) {
            return (key, display)
        }
        return stripUnderMouse() ?? enabledDisplays.first.map { (activeKey(for: $0), $0) }
    }

    func stripUnderMouse() -> (key: StripKey, display: DisplayInfo)? {
        guard let display = display(containing: services.input.mouseLocation()), isEnabledDisplay(display.uuid) else { return nil }
        return (activeKey(for: display), display)
    }

    /// Stores `strip` with its viewport adjusted to show the focused column.
    func storeRevealed(_ strip: Strip, for key: StripKey) {
        guard let display = display(forKey: key) else {
            world = world.setting(strip, for: key)
            return
        }
        world = world.setting(LayoutEngine.revealFocused(strip, area: workingArea(display), config: layoutConfig), for: key)
    }

    func revealAllActiveStrips() {
        for display in enabledDisplays {
            let key = activeKey(for: display)
            storeRevealed(world.strip(key), for: key)
        }
    }

    func refreshDisplays() {
        let fresh = services.screens.displays()
        guard !fresh.isEmpty else { return }
        displays = fresh
        let known = Set(fresh.map(\.uuid))
        guard let main = mainDisplay else { return }
        let target = activeKey(for: main)
        for key in world.strips.keys where !known.contains(key.displayUUID) {
            world = world.mergingStrip(key, into: target)
        }
    }

    func screensChanged() {
        guard isEnabled else { return }
        refreshDisplays()
        revealAllActiveStrips()
        relayout(animated: false, force: true)
    }

    // MARK: Relayout

    /// Lays out every active strip on every enabled display. Without `force`, windows
    /// already at (or animating to) their target are left alone.
    func relayout(animated: Bool, force: Bool = false) {
        guard isEnabled else { return }
        let config = layoutConfig
        let now = services.scheduler.now()
        let spec = animated && settings.animation.enabled ? AnimationSpec(spring: settings.animation.effectiveSpring) : nil
        var focusFrame: (CGRect, DisplayInfo)?
        var bars: [TabBarModel] = []
        for display in enabledDisplays {
            let key = activeKey(for: display)
            let strip = world.strip(key)
            guard !strip.isEmpty else { continue }
            let context = layoutContext(display)
            let placements = LayoutEngine.placements(strip, context: context, config: config)
            var current: [WindowID: CGRect] = [:]
            for p in placements {
                current[p.window] = services.applier.expectedFrame(of: p.window) ?? infos[p.window]?.frame
            }
            var transitions = LayoutEngine.transitions(placements, currentFrames: current, context: context, config: config)
            if !force {
                transitions = transitions.filter { id, t in
                    t.start != nil || !(services.applier.expectedFrame(of: id)?.isApproximatelyEqual(to: t.settledFrame, tolerance: 0.5) ?? false)
                }
            }
            for id in transitions.keys { lastLayoutTime[id] = now }
            if !transitions.isEmpty { services.applier.apply(transitions, animation: spec) }
            if let p = placements.first(where: { $0.window == focusedWindowID && !$0.visibility.isHidden }) {
                focusFrame = (p.frame, display)
            }
            bars += tabBars(strip: strip, placements: placements, area: context.area, config: config)
        }
        let focus = (frame: focusFrame?.0, display: focusFrame?.1.uuid)
        if lastFocusOverlay.map({ $0.frame != focus.frame || $0.display != focus.display }) ?? true {
            lastFocusOverlay = focus
            services.overlays.updateFocus(frame: focusFrame?.0, display: focusFrame?.1)
        }
        if lastTabBars != bars {
            lastTabBars = bars
            services.overlays.updateTabBars(bars)
        }
        scheduleSave()
    }

    private func tabBars(strip: Strip, placements: [WindowPlacement], area: CGRect, config: LayoutConfig) -> [TabBarModel] {
        guard config.tabBarHeight > 0 else { return [] }
        // Placements are already in column/row order. Visit them once instead of
        // searching all placements again for each tabbed column.
        return placements.compactMap { active in
            let column = strip.columns[active.columnIndex]
            guard column.mode == .tabbed, active.row == column.activeIndex,
                  !active.visibility.isHidden else { return nil }
            let frame = CGRect(x: active.frame.minX, y: area.minY, width: active.frame.width, height: CGFloat(config.tabBarHeight))
            let tabs = column.windows.map { id in
                TabBarModel.Tab(window: id, title: infos[id]?.title ?? "", appName: infos[id]?.appName ?? "", bundleID: infos[id]?.bundleID)
            }
            return TabBarModel(frame: frame, tabs: tabs, activeIndex: column.activeIndex)
        }
    }

    /// Puts every hidden window of every known strip back on its display (centred,
    /// cascading), so nothing stays parked when Ribbon stops. A window caught mid-slide
    /// (an animation cancelled while it was still mostly off-screen) is sent to its
    /// on-screen spot too.
    func unparkAll() {
        let config = layoutConfig
        var transitions: [WindowID: FrameTransition] = [:]
        for (key, strip) in world.strips {
            guard let display = display(forKey: key) ?? mainDisplay else { continue }
            let placements = LayoutEngine.placements(strip, context: layoutContext(display), config: config)
            let visible = display.visibleFrame
            var step: CGFloat = 0
            for p in placements where p.visibility.isHidden || !isActiveKey(key) {
                let size = CGSize(width: min(p.frame.width, visible.width * 0.9), height: min(p.frame.height, visible.height * 0.9))
                var origin = CGPoint(x: visible.midX - size.width / 2 + step, y: visible.midY - size.height / 2 + step)
                origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
                origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
                transitions[p.window] = FrameTransition(target: CGRect(origin: origin, size: size).roundedToPoints)
                step = (step + Self.cascadeStep).truncatingRemainder(dividingBy: Self.cascadeStep * 8)
            }
            guard isActiveKey(key) else { continue }
            for p in placements where !p.visibility.isHidden {
                guard let current = services.applier.expectedFrame(of: p.window), current.width > 0, current.height > 0,
                      current.intersectionArea(with: display.frame) < current.width * current.height / 2 else { continue }
                transitions[p.window] = FrameTransition(target: p.frame)
            }
        }
        if !transitions.isEmpty { services.applier.apply(transitions, animation: nil) }
    }
}

extension Visibility {
    var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }
}
