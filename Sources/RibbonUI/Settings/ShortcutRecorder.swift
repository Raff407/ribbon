import AppKit
import Combine
import RibbonCore
import RibbonInput

/// Which shortcut slot is being recorded: an existing binding (by index into
/// `RibbonSettings.bindings`) or a new one for a command.
enum RecordingTarget: Equatable {
    case existing(index: Int)
    case new(Command)
}

/// What the user did while recording.
enum RecordingResult: Equatable {
    case recorded(KeyCombo)
    /// ⌫ / ⌦: remove the binding.
    case cleared
    case cancelled
}

/// Records one key combination at a time with a local keyDown monitor (the settings
/// window is key while recording). Suspends Ribbon's global hotkeys meanwhile so the
/// combination being typed doesn't also fire its current command. Main thread only.
final class ShortcutRecorderCoordinator: ObservableObject {
    @Published private(set) var target: RecordingTarget?

    private let setHotkeysSuspended: (Bool) -> Void
    private var monitor: Any?
    private var completion: ((RecordingResult) -> Void)?

    init(setHotkeysSuspended: @escaping (Bool) -> Void) {
        self.setHotkeysSuspended = setHotkeysSuspended
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func isRecording(_ candidate: RecordingTarget) -> Bool { target == candidate }

    func start(_ newTarget: RecordingTarget, completion: @escaping (RecordingResult) -> Void) {
        finish(.cancelled)
        target = newTarget
        self.completion = completion
        setHotkeysSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.finish(Self.interpret(keyCode: UInt32(event.keyCode), modifiers: KeyNames.modifiers(from: event.modifierFlags)))
            return nil
        }
    }

    /// Ends any recording in progress (window closed, pane switched).
    func stop() {
        finish(.cancelled)
    }

    /// Pure mapping from a key press to a result. A shortcut needs ⌃, ⌥ or ⌘ (⇧ alone
    /// would steal ordinary typing); a bare Esc cancels and a bare ⌫/⌦ clears.
    static func interpret(keyCode: UInt32, modifiers: ModifierSet) -> RecordingResult {
        let bare = modifiers.subtracting(.shift).isEmpty
        if bare && keyCode == KeyCode.escape { return .cancelled }
        if bare && (keyCode == KeyCode.delete || keyCode == 0x75) { return .cleared }
        guard !modifiers.intersection([.control, .option, .command]).isEmpty else { return .cancelled }
        return .recorded(KeyCombo(keyCode: keyCode, modifiers: modifiers))
    }

    private func finish(_ result: RecordingResult) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard target != nil else { return }
        let completion = self.completion
        self.completion = nil
        target = nil
        setHotkeysSuspended(false)
        completion?(result)
    }
}
