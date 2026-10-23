import RibbonCore
import SwiftUI

/// Gaps, scrolling behaviour and column widths.
struct LayoutPane: View {
    @ObservedObject var store: SettingsStore

    private typealias Range = SettingsSanitizer.Range

    var body: some View {
        Form {
            Section("Gaps") {
                SliderRow(title: "Between windows", value: store.binding(\.layout.gap),
                          range: Range.gap, step: 1, format: ValueFormat.points)
                SliderRow(title: "Around the edges", value: store.binding(\.layout.outerGap),
                          range: Range.outerGap, step: 1, format: ValueFormat.points)
            }
            Section("Scrolling") {
                Picker("Centre the focused window", selection: store.binding(\.layout.centreMode)) {
                    ForEach(CentreMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                HelpText(store.settings.layout.centreMode.explanation)
                ToggleRow(title: "Loop around at the ends",
                          detail: "Going right from the last window jumps to the first, and left from the first to the last. Moving windows loops the same way.",
                          isOn: store.binding(\.layout.wrapsAround))
            }
            Section("Column Widths") {
                SliderRow(title: "New window width", value: store.binding(\.layout.defaultWidthFraction),
                          range: Range.widthFraction, step: 0.05, format: ValueFormat.percent)
                WidthPresetsEditor(presets: store.binding(\.layout.widthPresets))
                SliderRow(title: "Wider / narrower step", value: store.binding(\.layout.widthStep),
                          range: Range.step, step: 0.05, format: ValueFormat.percent)
                SliderRow(title: "Taller / shorter step", value: store.binding(\.layout.heightStep),
                          range: Range.step, step: 0.05, format: ValueFormat.percent)
            }
        }
        .formStyle(.grouped)
    }
}

extension CentreMode {
    var title: String {
        switch self {
        case .never: return "Never"
        case .onOverflow: return "When the strip overflows"
        case .always: return "Always"
        }
    }

    var explanation: String {
        switch self {
        case .never: return "The strip scrolls just far enough to show the focused window."
        case .onOverflow: return "Windows stay left-aligned while they fit; after that the focused one is centred."
        case .always: return "The focused window always sits in the middle of the screen."
        }
    }
}
