import AppKit
import RibbonCore
import SwiftUI
import UniformTypeIdentifiers

/// Automatic floating and per-app rules.
struct RulesPane: View {
    @ObservedObject var store: SettingsStore
    private let icons = AppIconCache()

    var body: some View {
        Form {
            Section("Automatic floating") {
                ToggleRow(title: "Float dialogs and panels",
                          detail: "Dialogs, Quick Look and floating panels stay above the strip instead of becoming columns.",
                          isOn: store.binding(\.behavior.floatDialogs))
                ToggleRow(title: "Float fixed-size windows",
                          detail: "Windows that can't be resized, like Calculator, float on their own.",
                          isOn: store.binding(\.behavior.floatFixedSizeWindows))
            }
            Section("App rules") {
                if store.settings.rules.isEmpty {
                    HelpText("No rules yet. Add an app to always float it, always tile it, or leave it alone.")
                }
                ForEach(store.settings.rules) { rule in
                    HStack {
                        Image(nsImage: icons.icon(bundleID: rule.bundleID)).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading) {
                            Text(rule.appName)
                            Text(rule.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: actionBinding(for: rule.bundleID)) {
                            Text("Float").tag(AppRuleAction.float)
                            Text("Always tile").tag(AppRuleAction.tile)
                            Text("Ignore").tag(AppRuleAction.ignore)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Button { remove(rule.bundleID) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Spacer()
                    Menu("Add App") {
                        ForEach(runningApps, id: \.bundleID) { app in
                            Button(app.name) { add(bundleID: app.bundleID, name: app.name) }
                        }
                        Divider()
                        Button("Choose…") { chooseApp() }
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var runningApps: [(bundleID: String, name: String)] {
        let taken = Set(store.settings.rules.map(\.bundleID))
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own, !taken.contains(id) else { return nil }
            return (id, app.localizedName ?? id)
        }
        return Dictionary(apps, uniquingKeysWith: { first, _ in first })
            .map { (bundleID: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func actionBinding(for bundleID: String) -> Binding<AppRuleAction> {
        Binding(
            get: { store.settings.rule(for: bundleID)?.action ?? .float },
            set: { action in
                store.update { settings in
                    settings.setting(\.rules, to: settings.rules.map { rule in
                        rule.bundleID == bundleID ? AppRule(bundleID: rule.bundleID, appName: rule.appName, action: action) : rule
                    })
                }
            }
        )
    }

    private func add(bundleID: String, name: String) {
        store.update { settings in
            guard settings.rule(for: bundleID) == nil else { return settings }
            return settings.setting(\.rules, to: settings.rules + [AppRule(bundleID: bundleID, appName: name, action: .float)])
        }
    }

    private func remove(_ bundleID: String) {
        store.update { $0.setting(\.rules, to: $0.rules.filter { $0.bundleID != bundleID }) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            Log.settings.error("No bundle id for \(url.path, privacy: .public)")
            return
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(bundleID: id, name: name)
    }
}
