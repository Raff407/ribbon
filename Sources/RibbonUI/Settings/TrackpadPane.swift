import RibbonCore
import SwiftUI

/// Scroll-with-modifier and multi-finger swipe settings.
struct TrackpadPane: View {
    @ObservedObject var store: SettingsStore

    private typealias Range = SettingsSanitizer.Range
    private static let modifierChoices: [(ModifierSet, String)] = [
        (.control, "⌃ Control"), (.option, "⌥ Option"), (.shift, "⇧ Shift"), (.command, "⌘ Command"),
    ]

    var body: some View {
        Form {
            Section("Scroll with a modifier") {
                ToggleRow(title: "Scroll the strip while holding modifiers",
                          detail: "Two-finger swipe or mouse wheel while the keys below are held.",
                          isOn: store.binding(\.trackpad.scrollWithModifierEnabled))
                HStack {
                    ForEach(Self.modifierChoices, id: \.1) { choice in
                        Toggle(choice.1, isOn: store.binding(\.trackpad.scrollModifiers).contains(choice.0))
                            .toggleStyle(.button)
                    }
                }
                .disabled(!store.settings.trackpad.scrollWithModifierEnabled)
                if store.settings.trackpad.scrollModifiers.isEmpty {
                    StatusLine(isOK: false, text: "Pick at least one modifier — scrolling stays off until you do.")
                }
            }
            Section("Multi-finger swipe") {
                ToggleRow(title: "Swipe to scroll the strip",
                          detail: "The strip follows your fingers one to one, then settles on the nearest column.",
                          isOn: store.binding(\.trackpad.swipeEnabled))
                Picker("Fingers", selection: store.binding(\.trackpad.swipeFingers)) {
                    Text("Three").tag(3)
                    Text("Four").tag(4)
                }
                .pickerStyle(.segmented)
                .disabled(!store.settings.trackpad.swipeEnabled)
                HStack(alignment: .top) {
                    HelpText("macOS uses three- and four-finger swipes to switch Spaces. Turn that off in System Settings → Trackpad → More Gestures first.")
                    Spacer()
                    Button("Open Trackpad Settings") { SystemSettingsLink.trackpad.open() }
                }
            }
            Section("Feel") {
                SliderRow(title: "Sensitivity", value: store.binding(\.trackpad.sensitivity),
                          range: Range.sensitivity, step: 0.05, format: ValueFormat.multiplier)
                Toggle("Reverse direction", isOn: store.binding(\.trackpad.invertDirection))
            }
        }
        .formStyle(.grouped)
    }
}
