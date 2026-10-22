import AppKit
import RibbonCore
import SwiftUI

/// Focus border, dimming, strip indicator and tab bars.
struct AppearancePane: View {
    @ObservedObject var store: SettingsStore

    private typealias Range = SettingsSanitizer.Range

    var body: some View {
        Form {
            Section("Focus border") {
                Toggle("Draw a border around the focused window", isOn: store.binding(\.appearance.focusBorderEnabled))
                Group {
                    SliderRow(title: "Width", value: store.binding(\.appearance.focusBorderWidth),
                              range: Range.borderWidth, step: 1, format: ValueFormat.points)
                    SliderRow(title: "Corner radius", value: store.binding(\.appearance.focusBorderCornerRadius),
                              range: Range.cornerRadius, step: 1, format: ValueFormat.points)
                    ColorPicker("Colour", selection: colorBinding, supportsOpacity: true)
                }
                .disabled(!store.settings.appearance.focusBorderEnabled)
            }
            Section("Dim inactive windows") {
                Toggle("Dim everything except the focused window", isOn: store.binding(\.appearance.dimInactiveEnabled))
                SliderRow(title: "Amount", value: store.binding(\.appearance.dimAmount),
                          range: Range.dimAmount, step: 0.05, format: ValueFormat.percent)
                    .disabled(!store.settings.appearance.dimInactiveEnabled)
            }
            Section("Strip indicator") {
                ToggleRow(title: "Show the strip indicator while navigating",
                          detail: "Keep holding your shortcut key (⌥) to keep it up; click a tile to jump to it or drag tiles to reorder.",
                          isOn: store.binding(\.appearance.indicatorEnabled))
                SliderRow(title: "Stays visible for", value: store.binding(\.appearance.indicatorDuration),
                          range: Range.indicatorDuration, step: 0.1, format: ValueFormat.seconds)
                    .disabled(!store.settings.appearance.indicatorEnabled)
            }
            Section("Tabbed columns") {
                Toggle("Show a tab bar above tabbed columns", isOn: store.binding(\.appearance.tabBarsEnabled))
            }
        }
        .formStyle(.grouped)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexString: store.settings.appearance.focusBorderColorHex) ?? .controlAccentColor) },
            set: { color in
                if let hex = NSColor(color).hexString { store.set(\.appearance.focusBorderColorHex, to: hex) }
            }
        )
    }
}
