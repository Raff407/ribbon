import AppKit
import RibbonCore
import RibbonInput

/// The menu bar item: status, pause/resume, gather, settings, debug info, quit.
/// The menu is rebuilt every time it opens, so it always reflects the engine's state.
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: SettingsStore
    private let actions: AppActions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    public init(store: SettingsStore, actions: AppActions) {
        self.store = store
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Re-reads state (enabled flag, counts) into the menu.
    public func refresh() {
        let enabled = actions.isEnabled()
        let symbol = enabled ? "rectangle.split.3x1" : "rectangle.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: enabled ? "Ribbon" : "Ribbon (paused)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = enabled ? "Ribbon" : "Ribbon — paused"
    }

    public func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let enabled = actions.isEnabled()
        let count = actions.managedWindowCount()
        let status = NSMenuItem(title: enabled ? "Ribbon — \(count) window\(count == 1 ? "" : "s")" : "Ribbon — paused",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let toggle = item(enabled ? "Pause Ribbon" : "Resume Ribbon", #selector(toggleEnabled))
        if let combo = store.settings.bindings.first(where: { $0.command == .toggleEnabled })?.combo {
            toggle.title += "\t" + KeyNames.display(combo)
        }
        menu.addItem(toggle)
        menu.addItem(item("Gather All Windows", #selector(gather)))
        menu.addItem(item("Re-layout Now", #selector(relayout)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Copy Debug Info", #selector(copyDebugInfo)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Ribbon", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        actions.setEnabled(!actions.isEnabled())
        refresh()
    }

    @objc private func gather() { actions.gatherWindows() }
    @objc private func relayout() { actions.relayout() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func quit() { actions.quit() }

    @objc private func copyDebugInfo() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(actions.debugDump(), forType: .string)
    }
}
