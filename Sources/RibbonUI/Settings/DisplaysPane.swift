import RibbonCore
import SwiftUI

/// Turn Ribbon off for individual displays.
struct DisplaysPane: View {
    @ObservedObject var store: SettingsStore
    let actions: AppActions

    var body: some View {
        let displays = actions.displays()
        Form {
            Section {
                HelpText("Every display has its own strip. Switch Ribbon off for a display (a presentation screen, a portrait monitor) and its windows stay exactly where you put them.")
            }
            Section("Displays") {
                if displays.isEmpty {
                    HelpText("Display information appears once Ribbon is running.")
                }
                ForEach(displays, id: \.uuid) { display in
                    Toggle(isOn: managedBinding(display.uuid)) {
                        HStack {
                            Image(systemName: display.isMain ? "display" : "display.2")
                            RowLabel(title: display.name + (display.isMain ? " (main)" : ""),
                                     detail: "\(Int(display.frame.width)) × \(Int(display.frame.height))")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func managedBinding(_ uuid: String) -> Binding<Bool> {
        Binding(
            get: { !store.settings.disabledDisplays.contains(uuid) },
            set: { managed in
                store.update { settings in
                    let others = settings.disabledDisplays.filter { $0 != uuid }
                    return settings.setting(\.disabledDisplays, to: managed ? others : others + [uuid])
                }
            }
        )
    }
}
