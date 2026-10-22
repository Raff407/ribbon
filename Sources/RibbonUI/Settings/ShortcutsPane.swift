import RibbonCore
import RibbonInput
import SwiftUI

/// Every command with its bindings; click a shortcut to re-record it, "+" to add one.
struct ShortcutsPane: View {
    @ObservedObject var store: SettingsStore
    let actions: AppActions
    @ObservedObject var recorder: ShortcutRecorderCoordinator

    var body: some View {
        let conflicts = store.settings.conflictingCombos
        let failed = Set(actions.failedBindings())
        Form {
            Section {
                HelpText("Click a shortcut and type the new keys. Shortcuts need ⌃, ⌥ or ⌘. Press ⌫ to remove one, Esc to cancel.")
                HStack {
                    Spacer()
                    Menu("Use Preset") {
                        ForEach(ShortcutPreset.allCases, id: \.self) { preset in
                            Button(preset.title) {
                                recorder.stop()
                                store.set(\.bindings, to: DefaultBindings.preset(preset))
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            ForEach(CommandCategory.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(Command.allCases.filter { $0.category == category }, id: \.id) { command in
                        row(for: command, conflicts: conflicts, failed: failed)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recorder.stop() }
    }

    private func row(for command: Command, conflicts: Set<KeyCombo>, failed: Set<KeyBinding>) -> some View {
        let indices = store.settings.bindings.indices.filter { store.settings.bindings[$0].command == command }
        return LabeledContent(command.title) {
            HStack(spacing: 6) {
                ForEach(indices, id: \.self) { index in
                    let binding = store.settings.bindings[index]
                    ShortcutChip(
                        text: recorder.isRecording(.existing(index: index)) ? "Type shortcut…" : KeyNames.display(binding.combo),
                        isRecording: recorder.isRecording(.existing(index: index)),
                        isConflict: conflicts.contains(binding.combo),
                        isFailed: failed.contains(binding)
                    ) { record(.existing(index: index)) }
                }
                if recorder.isRecording(.new(command)) {
                    ShortcutChip(text: "Type shortcut…", isRecording: true, isConflict: false, isFailed: false) { recorder.stop() }
                } else {
                    Button { record(.new(command)) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a shortcut for \(command.title)")
                }
            }
        }
    }

    private func record(_ target: RecordingTarget) {
        if recorder.isRecording(target) {
            recorder.stop()
            return
        }
        recorder.start(target) { result in
            store.update { Self.applying(result, to: target, in: $0) }
        }
    }

    /// Pure: the settings after a recording finished.
    static func applying(_ result: RecordingResult, to target: RecordingTarget, in settings: RibbonSettings) -> RibbonSettings {
        var bindings = settings.bindings
        switch (result, target) {
        case (.cancelled, _), (.cleared, .new):
            return settings
        case (.cleared, .existing(let index)):
            guard bindings.indices.contains(index) else { return settings }
            bindings.remove(at: index)
        case (.recorded(let combo), .existing(let index)):
            guard bindings.indices.contains(index) else { return settings }
            bindings[index] = KeyBinding(command: bindings[index].command, combo: combo)
        case (.recorded(let combo), .new(let command)):
            let binding = KeyBinding(command: command, combo: combo)
            guard !bindings.contains(binding) else { return settings }
            bindings.append(binding)
        }
        return settings.setting(\.bindings, to: bindings)
    }
}

/// One shortcut as a clickable capsule.
private struct ShortcutChip: View {
    let text: String
    let isRecording: Bool
    let isConflict: Bool
    let isFailed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isFailed && !isRecording {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
                Text(text).font(.system(.body, design: .rounded)).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isConflict ? Color.red : (isRecording ? Color.accentColor : Color.clear), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(isFailed ? "macOS refused this shortcut — another app probably uses it."
              : (isConflict ? "This shortcut is bound to more than one command." : "Click to change"))
    }
}
