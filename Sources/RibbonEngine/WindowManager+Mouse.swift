import CoreGraphics
import Foundation
import RibbonCore

// Mouse drags, focus-follows-mouse and trackpad gestures.
extension WindowManager {
    func mouseUp() {
        guard isEnabled, let id = draggedWindow else { return }
        draggedWindow = nil
        finishDrag(of: id)
    }

    /// A user drag/resize of a tiled window ended: adopt a new size, move it to another
    /// column or display, or snap it back.
    func finishDrag(of id: WindowID) {
        defer { relayout(animated: true, force: true) }
        guard let key = world.key(containing: id), let display = display(forKey: key),
              let frame = services.windows.frame(of: id), let expected = services.applier.expectedFrame(of: id) else { return }
        let tolerance = Self.ownMoveTolerance
        let resizedWidth = abs(frame.width - expected.width) > tolerance
        let resizedHeight = abs(frame.height - expected.height) > tolerance
        if resizedWidth || resizedHeight {
            if resizedWidth { adoptDraggedWidth(frame, expected: expected, of: id, key: key, display: display) }
            if resizedHeight { adoptHeight(frame.height, of: id, key: key, display: display) }
            return
        }
        guard abs(frame.minX - expected.minX) > tolerance || abs(frame.minY - expected.minY) > tolerance else { return }
        let mouse = services.input.mouseLocation()
        if let target = self.display(containing: mouse), target.uuid != display.uuid, isEnabledDisplay(target.uuid) {
            moveDraggedWindow(id, from: key, to: target, at: mouse)
            return
        }
        let strip = world.strip(key)
        guard let loc = strip.location(of: id) else { return }
        let placements = LayoutEngine.placements(strip, context: layoutContext(display), config: layoutConfig)
            .filter { $0.columnIndex != loc.column }
        if let column = LayoutEngine.columnIndex(at: mouse, placements: placements) {
            world = world.setting(strip.movingColumn(from: loc.column, to: column), for: key)
        }
    }

    /// The edge that moved more is the one the user dragged; a visible neighbour on that
    /// side absorbs the change (see `Strip.resizingByDrag`).
    private func adoptDraggedWidth(_ frame: CGRect, expected: CGRect, of id: WindowID, key: StripKey, display: DisplayInfo) {
        let edge: Side = abs(frame.minX - expected.minX) > abs(frame.maxX - expected.maxX) ? .left : .right
        let strip = world.strip(key)
        let visible = Set(LayoutEngine.placements(strip, context: layoutContext(display), config: layoutConfig)
            .filter { !$0.visibility.isHidden }.map(\.columnIndex))
        let resized = strip.resizingByDrag(
            id, toWidth: Double(frame.width), edge: edge, areaWidth: Double(workingArea(display).width),
            visibleColumns: visible, adjustNeighbour: settings.behavior.resizeAdjustsNeighbour, config: layoutConfig
        )
        world = world.setting(LayoutEngine.clampViewport(resized, area: workingArea(display), config: layoutConfig), for: key)
    }

    private func adoptHeight(_ height: CGFloat, of id: WindowID, key: StripKey, display: DisplayInfo) {
        let strip = world.strip(key)
        guard let loc = strip.location(of: id) else { return }
        let count = strip.columns[loc.column].windows.count
        guard count > 1 else { return }
        let available = Double(workingArea(display).height) - settings.layout.gap * Double(count - 1)
        guard available > 0 else { return }
        world = world.setting(strip.settingHeightShare(Double(height) / available, of: id), for: key)
    }

    private func moveDraggedWindow(_ id: WindowID, from key: StripKey, to display: DisplayInfo, at point: CGPoint) {
        let source = world.strip(key)
        let width = source.location(of: id).map { source.columns[$0.column].widthFraction } ?? settings.layout.defaultWidthFraction
        let target = activeKey(for: display)
        let placements = LayoutEngine.placements(world.strip(target), context: layoutContext(display), config: layoutConfig)
        let position: InsertPosition = LayoutEngine.columnIndex(at: point, placements: placements).map { .at($0) } ?? .end
        world = world.tiling(id, into: target, position: position, widthFraction: width, focus: true)
        storeRevealed(world.strip(key), for: key)
        storeRevealed(world.strip(target), for: target)
        focusedWindowID = id
    }

    // MARK: Focus follows mouse

    func mouseMoved(to point: CGPoint) {
        guard isEnabled, settings.behavior.focusFollowsMouse else { return }
        debounce("ffm", 0.1) { [weak self] in self?.focusWindow(under: point) }
    }

    func focusWindow(under point: CGPoint) {
        guard isEnabled, !services.input.isLeftMouseDown, !services.applier.isAnimating, gestureKey == nil,
              let display = display(containing: point), isEnabledDisplay(display.uuid) else { return }
        let key = activeKey(for: display)
        let strip = world.strip(key)
        let placements = LayoutEngine.placements(strip, context: layoutContext(display), config: layoutConfig)
        guard let hit = placements.first(where: { $0.visibility == .visible && $0.frame.contains(point) }),
              hit.window != focusedWindowID else { return }
        suppressRevealFor = hit.window
        world = world.setting(strip.focusing(hit.window), for: key)
        focus(hit.window)
        relayout(animated: false)
    }

    // MARK: Gestures

    func handleGesture(_ event: GestureEvent) {
        guard isEnabled else { return }
        switch event {
        case .began:
            beginGesture()
        case .changed(let dx):
            if gestureKey == nil { beginGesture() }
            guard let key = gestureKey else { return }
            let strip = world.strip(key)
            world = world.setting(Strip(columns: strip.columns, focusedColumnIndex: strip.focusedColumnIndex,
                                        viewportOffset: strip.viewportOffset + dx), for: key)
            relayout(animated: false)
            showIndicator()
        case .ended(let velocity):
            endGesture(velocity: velocity)
        case .cancelled:
            endGesture(velocity: 0)
        }
    }

    private func beginGesture() {
        guard let (key, _) = stripUnderMouse() ?? activeStrip(), !world.strip(key).isEmpty else { return }
        gestureKey = key
        services.applier.cancelAll()
    }

    private func endGesture(velocity: Double) {
        guard let key = gestureKey else { return }
        gestureKey = nil
        guard let display = display(forKey: key) else { return }
        let before = world.strip(key)
        let snapped = LayoutEngine.snap(before, area: workingArea(display), config: layoutConfig, velocity: velocity)
        world = world.setting(snapped, for: key)
        if let id = snapped.focusedWindow, id != focusedWindowID, snapped.focusedColumnIndex != before.focusedColumnIndex {
            suppressRevealFor = id
            focus(id)
        }
        relayout(animated: true)
        showIndicator()
    }
}
