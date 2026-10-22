import AppKit
import ApplicationServices
import SwiftUI

/// Checks the macOS settings that make a scrolling window manager behave.
struct MacSetupPane: View {
    @State private var checks: [MacSetupCheck] = MacSetupCheck.runAll()

    var body: some View {
        Form {
            Section {
                HelpText("Ribbon works best with these macOS settings. Nothing here is changed for you.")
            }
            Section("Checks") {
                ForEach(checks) { check in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            StatusLine(isOK: check.isOK, text: check.title)
                            if !check.isOK { HelpText(check.advice) }
                        }
                        Spacer()
                        if !check.isOK, let link = check.link {
                            Button("Open Settings") { link.open() }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Check Again") { checks = MacSetupCheck.runAll() }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checks = MacSetupCheck.runAll()
        }
    }
}

struct MacSetupCheck: Identifiable {
    let id: String
    let title: String
    let isOK: Bool
    let advice: String
    let link: SystemSettingsLink?

    /// Window managers and snapping apps that fight over the same windows.
    static let conflictingApps: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle", "com.knollsoft.Hookshot": "Hookshot",
        "com.crowdcafe.windowmagnet": "Magnet", "com.amethyst.Amethyst": "Amethyst",
        "bobko.aerospace": "AeroSpace", "com.mizage.Divvy": "Divvy",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool", "com.manytricks.Moom": "Moom",
    ]

    static func runAll() -> [MacSetupCheck] {
        let spaces = UserDefaults(suiteName: "com.apple.spaces")
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let windowManager = UserDefaults(suiteName: "com.apple.WindowManager")
        let running = NSWorkspace.shared.runningApplications
        var others = running.compactMap { $0.bundleIdentifier.flatMap { conflictingApps[$0] } }
        if running.contains(where: { $0.localizedName == "yabai" || $0.executableURL?.lastPathComponent == "yabai" }) {
            others.append("yabai")
        }
        return [
            MacSetupCheck(id: "ax", title: "Accessibility permission granted", isOK: AXIsProcessTrusted(),
                          advice: "Ribbon can't move windows without it.", link: .accessibility),
            MacSetupCheck(id: "separate", title: "Displays have separate Spaces",
                          isOK: !(spaces?.bool(forKey: "spans-displays") ?? false),
                          advice: "Turn on “Displays have separate Spaces” (Desktop & Dock → Mission Control). Log out to apply.",
                          link: .desktopAndDock),
            MacSetupCheck(id: "mru", title: "Spaces stay in order",
                          isOK: !((dock?.object(forKey: "mru-spaces") as? Bool) ?? true),
                          advice: "Turn off “Automatically rearrange Spaces based on most recent use”.",
                          link: .desktopAndDock),
            MacSetupCheck(id: "stage", title: "Stage Manager is off",
                          isOK: !(windowManager?.bool(forKey: "GloballyEnabled") ?? false),
                          advice: "Stage Manager moves windows on its own; switch it off in Desktop & Dock.",
                          link: .desktopAndDock),
            MacSetupCheck(id: "others", title: others.isEmpty ? "No other window manager running" : "Also running: \(others.joined(separator: ", "))",
                          isOK: others.isEmpty,
                          advice: "Quit other window managers and snapping apps so they don't move the same windows.",
                          link: nil),
        ]
    }
}
