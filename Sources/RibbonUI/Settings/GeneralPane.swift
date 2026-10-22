import AppKit
import RibbonCore
import SwiftUI

/// Startup, new-window placement, focus behaviour and animation.
struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var launchAtLogin = LaunchAtLoginModel()

    var body: some View {
        Form {
            startupSection
            windowsSection
            focusSection
            animationSection
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch Ribbon at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            if let text = launchAtLogin.statusText {
                HStack {
                    StatusLine(isOK: false, text: text)
                    Spacer()
                    if launchAtLogin.needsApproval {
                        Button("Open Login Items") { SystemSettingsLink.loginItems.open() }
                    }
                }
            }
            if let error = launchAtLogin.errorMessage {
                Text(error).font(.callout).foregroundColor(.red)
            }
            ToggleRow(
                title: "Restore the layout on launch",
                detail: "Puts windows back in the columns they were in when Ribbon quit.",
                isOn: store.binding(\.behavior.restoreSession)
            )
        }
    }

    private var windowsSection: some View {
        Section("New Windows") {
            Picker("Open new windows", selection: store.binding(\.behavior.newWindowPosition)) {
                ForEach(NewWindowPosition.allCases, id: \.self) { position in
                    Text(position.title).tag(position)
                }
            }
        }
    }

    private var focusSection: some View {
        Section("Focus") {
            ToggleRow(
                title: "Focus follows mouse",
                detail: "Hovering over a visible window focuses it.",
                isOn: store.binding(\.behavior.focusFollowsMouse)
            )
            ToggleRow(
                title: "Mouse follows focus",
                detail: "Moves the pointer to the window you focus with the keyboard.",
                isOn: store.binding(\.behavior.mouseFollowsFocus)
            )
        }
    }

    private var animationSection: some View {
        Section("Animation") {
            Toggle("Animate window movement", isOn: store.binding(\.animation.enabled))
            SliderRow(
                title: "Speed",
                value: store.binding(\.animation.speed),
                range: SettingsSanitizer.Range.animationSpeed,
                step: 0.1,
                format: ValueFormat.multiplier
            )
            .disabled(!store.settings.animation.enabled)
        }
    }
}

extension NewWindowPosition {
    var title: String {
        switch self {
        case .afterFocused: return "Next to the focused window"
        case .end: return "At the end of the strip"
        }
    }
}
