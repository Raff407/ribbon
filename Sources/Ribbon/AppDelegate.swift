import AppKit
import Combine
import os
import RibbonAX
import RibbonCore
import RibbonEngine
import RibbonInput
import RibbonUI

let appLog = Logger(subsystem: "com.raff.ribbon", category: "App")

/// Owns every long-lived object and wires them together.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SettingsStore?
    private var services: AppServices?
    private var manager: WindowManager?
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private let onboarding = OnboardingWindowController()
    private let urlHandler = URLCommandHandler()
    private var signals: SignalHandler?
    private var settingsSubscription: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = urlHandler  // installs the Get URL handler before AppKit delivers a launch URL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isAnotherInstanceRunning() else {
            appLog.info("Another Ribbon is already running; quitting")
            NSApp.terminate(nil)
            return
        }
        let store = SettingsStore()
        let services = AppServices()
        let manager = WindowManager(services: services.engineServices, settings: store.settings,
                                    ownBundleID: Bundle.main.bundleIdentifier)
        self.store = store
        self.services = services
        self.manager = manager

        let actions = makeActions(manager: manager, services: services)
        settingsWindow = SettingsWindowController(store: store, actions: actions)
        menuBar = MenuBarController(store: store, actions: actions)
        manager.stateChangeHandler = { [weak self] in self?.menuBar?.refresh() }
        manager.openSettingsHandler = { [weak self] in self?.settingsWindow?.show() }
        settingsSubscription = store.$settings.dropFirst().removeDuplicates().sink { [weak manager] settings in
            manager?.updateSettings(settings)
        }
        urlHandler.openSettings = { [weak self] in self?.settingsWindow?.show() }
        urlHandler.manager = manager
        signals = SignalHandler { [weak manager] in manager?.stop() }

        if AccessibilityPermission.isTrusted(prompt: false) {
            manager.start()
            urlHandler.managerDidStart()
        } else {
            onboarding.show { [weak self, weak manager] in
                manager?.start()
                self?.urlHandler.managerDidStart()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return false
    }

    private func makeActions(manager: WindowManager, services: AppServices) -> AppActions {
        AppActions(
            isEnabled: { [weak manager] in manager?.isEnabled ?? false },
            setEnabled: { [weak manager] in manager?.setEnabled($0) },
            gatherWindows: { [weak manager] in manager?.gatherAllWindows() },
            relayout: { [weak manager] in manager?.relayout() },
            openSettings: { [weak self] in self?.settingsWindow?.show() },
            quit: { NSApp.terminate(nil) },
            displays: { [weak services] in services?.screens.displays() ?? [] },
            failedBindings: { [weak manager] in manager?.failedBindings ?? [] },
            setHotkeysSuspended: { [weak services] in services?.hotkeys.setSuspended($0) },
            debugDump: { [weak manager] in manager?.debugDescription() ?? "" },
            managedWindowCount: { [weak manager] in manager?.managedWindowCount ?? 0 }
        )
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me }
    }
}
