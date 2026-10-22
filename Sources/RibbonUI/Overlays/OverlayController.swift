import AppKit
import RibbonCore

/// The real `OverlayPresenting`: strip indicator, focus border, dim-inactive and tab
/// bars. Windows are created lazily on first use and reused. Every frame coming in is
/// AX space and is converted to Cocoa with the primary display's height.
///
/// Main thread only (like every platform protocol in RibbonCore).
public final class OverlayController: OverlayPresenting {
    public var tileClickHandler: ((Int) -> Void)?
    public var tileReorderHandler: ((Int, Int) -> Void)?
    public var tabClickHandler: ((WindowID) -> Void)?

    private var appearance = AppearanceSettings()
    private let icons = AppIconCache.shared

    private var indicatorWindow: StripIndicatorWindow?
    private var borderWindow: FocusBorderWindow?
    private var dimWindows: [DimOverlayWindow] = []
    private var tabBarWindows: [TabBarWindow] = []

    /// Last focus request, re-applied when the appearance changes so edits in Settings
    /// show up immediately.
    private var focusFrame: CGRect?
    private var lastTabBars: [TabBarModel] = []

    public init() {}

    public func configure(_ appearance: AppearanceSettings) {
        let previous = self.appearance
        self.appearance = appearance
        if !appearance.indicatorEnabled { hideIndicator() }
        if appearance.tabBarsEnabled != previous.tabBarsEnabled { updateTabBars(lastTabBars) }
        applyFocus()
    }

    // MARK: - Strip indicator

    public func showIndicator(_ model: IndicatorModel, on display: DisplayInfo, persistent: Bool) {
        guard appearance.indicatorEnabled, !model.tiles.isEmpty else {
            hideIndicator()
            return
        }
        let window = indicatorWindow ?? makeIndicatorWindow()
        let tileIcons = model.tiles.map { icons.icon(pid: $0.pid, bundleID: $0.bundleID) }
        window.show(model, icons: tileIcons, visibleFrameAX: display.visibleFrame,
                    persistent: persistent, duration: appearance.indicatorDuration)
    }

    public func hideIndicator() {
        indicatorWindow?.hide(animated: true)
    }

    private func makeIndicatorWindow() -> StripIndicatorWindow {
        let window = StripIndicatorWindow()
        window.indicatorView.onTileClick = { [weak self] index in self?.tileClickHandler?(index) }
        window.indicatorView.onTileReorder = { [weak self] from, to in self?.tileReorderHandler?(from, to) }
        indicatorWindow = window
        return window
    }

    // MARK: - Focus border + dimming

    public func updateFocus(frame: CGRect?, display: DisplayInfo?) {
        focusFrame = frame
        applyFocus()
    }

    private func applyFocus() {
        let cocoaFrame = focusFrame.map(ScreenGeometry.cocoaRect(fromAX:))
        applyDim(hole: cocoaFrame)
        applyBorder(around: cocoaFrame)
    }

    private func applyBorder(around frame: CGRect?) {
        guard appearance.focusBorderEnabled, let frame else {
            borderWindow?.dismiss()
            return
        }
        let window = borderWindow ?? makeBorderWindow()
        window.style = FocusBorderStyle(
            width: CGFloat(appearance.focusBorderWidth),
            color: NSColor(hexString: appearance.focusBorderColorHex) ?? FocusBorderStyle.fallbackColor,
            cornerRadius: CGFloat(appearance.focusBorderCornerRadius)
        )
        // Ordered after the dim windows (same level), so the border stays on top.
        window.show(around: frame)
    }

    private func makeBorderWindow() -> FocusBorderWindow {
        let window = FocusBorderWindow()
        borderWindow = window
        return window
    }

    private func applyDim(hole: CGRect?) {
        guard appearance.dimInactiveEnabled, appearance.dimAmount > 0, let hole else {
            dimWindows.forEach { $0.dismiss() }
            return
        }
        let screens = ScreenGeometry.screenFrames
        while dimWindows.count < screens.count { dimWindows.append(DimOverlayWindow()) }
        for (index, window) in dimWindows.enumerated() {
            guard index < screens.count else { window.dismiss(); continue }
            window.show(screenFrame: screens[index], holeCocoa: hole,
                        amount: CGFloat(appearance.dimAmount),
                        cornerRadius: CGFloat(appearance.focusBorderCornerRadius))
        }
    }

    // MARK: - Tab bars

    public func updateTabBars(_ bars: [TabBarModel]) {
        lastTabBars = bars
        let visibleBars = appearance.tabBarsEnabled ? bars.filter { !$0.tabs.isEmpty } : []
        while tabBarWindows.count < visibleBars.count { tabBarWindows.append(makeTabBarWindow()) }
        for (index, window) in tabBarWindows.enumerated() {
            guard index < visibleBars.count else { window.dismiss(); continue }
            let bar = visibleBars[index]
            let tabIcons = bar.tabs.map { tab in
                icons.icon(pid: NSRunningApplication.pid(forBundleID: tab.bundleID), bundleID: tab.bundleID)
            }
            window.show(bar, icons: tabIcons)
        }
    }

    private func makeTabBarWindow() -> TabBarWindow {
        let window = TabBarWindow()
        window.barView.onTabClick = { [weak self] id in self?.tabClickHandler?(id) }
        return window
    }

    // MARK: - Everything

    public func hideAll() {
        indicatorWindow?.hide(animated: false)
        borderWindow?.dismiss()
        dimWindows.forEach { $0.dismiss() }
        tabBarWindows.forEach { $0.dismiss() }
        focusFrame = nil
        lastTabBars = []
    }
}

private extension NSRunningApplication {
    /// Tabs carry a bundle id but no pid; the cache only needs a pid when there's no
    /// bundle id, so any value works then.
    static func pid(forBundleID bundleID: String?) -> ProcessID {
        guard let bundleID else { return -1 }
        return runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier ?? -1
    }
}
