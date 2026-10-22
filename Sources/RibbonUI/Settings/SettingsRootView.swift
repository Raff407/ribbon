import RibbonCore
import SwiftUI

/// The sidebar entries of the settings window.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, layout, shortcuts, trackpad, appearance, rules, displays, macSetup, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .layout: return "Layout"
        case .shortcuts: return "Shortcuts"
        case .trackpad: return "Trackpad & Mouse"
        case .appearance: return "Appearance"
        case .rules: return "Window Rules"
        case .displays: return "Displays"
        case .macSetup: return "Mac Setup"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "rectangle.split.3x1"
        case .shortcuts: return "command"
        case .trackpad: return "hand.draw"
        case .appearance: return "paintpalette"
        case .rules: return "list.bullet.rectangle"
        case .displays: return "display.2"
        case .macSetup: return "checklist"
        case .about: return "info.circle"
        }
    }
}

/// Sidebar + detail. Every pane edits `store.settings` directly (changes apply
/// instantly; there is no Save button).
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    let actions: AppActions
    let recorder: ShortcutRecorderCoordinator

    @State private var selection: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail(for: selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(store: store)
        case .layout: LayoutPane(store: store)
        case .shortcuts: ShortcutsPane(store: store, actions: actions, recorder: recorder)
        case .trackpad: TrackpadPane(store: store)
        case .appearance: AppearancePane(store: store)
        case .rules: RulesPane(store: store)
        case .displays: DisplaysPane(store: store, actions: actions)
        case .macSetup: MacSetupPane()
        case .about: AboutPane()
        }
    }
}
