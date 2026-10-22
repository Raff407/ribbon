import AppKit
import RibbonCore
import RibbonEngine

/// Handles `ribbon://` URLs (used by the `ribbon` CLI, Raycast, Shortcuts…):
/// `ribbon://<command-id>`, `ribbon://command/<command-id>`, plus `enable`, `disable`,
/// `relayout`, `gather` and `settings`.
final class URLCommandHandler: NSObject {
    /// Set once the app is wired up; URLs that arrive before that (a `ribbon://` link that
    /// cold-launched Ribbon) are queued and run then.
    weak var manager: WindowManager? {
        didSet { flushPending() }
    }
    var openSettings: (() -> Void)?
    private var pending: [Action] = []

    /// Install in `applicationWillFinishLaunching`: AppKit delivers the launch URL before
    /// `applicationDidFinishLaunching`.
    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    deinit {
        NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let action = Self.action(for: string) else {
            appLog.error("Ignoring unrecognised URL")
            return
        }
        guard let manager, manager.isStarted || action == .settings else {
            pending.append(action)
            return
        }
        perform(action, on: manager)
    }

    private func flushPending() {
        guard let manager, manager.isStarted else { return }
        let queued = pending
        pending = []
        queued.forEach { perform($0, on: manager) }
    }

    /// Runs queued actions once the manager has started (after the permission prompt).
    func managerDidStart() { flushPending() }

    private func perform(_ action: Action, on manager: WindowManager?) {
        switch action {
        case .command(let command): manager?.perform(command)
        case .enable: manager?.setEnabled(true)
        case .disable: manager?.setEnabled(false)
        case .relayout: manager?.relayout()
        case .gather: manager?.gatherAllWindows()
        case .settings: openSettings?()
        }
    }

    enum Action: Equatable {
        case command(Command), enable, disable, relayout, gather, settings
    }

    /// Pure URL parsing. Accepts `ribbon://focus-left`, `ribbon://command/focus-left`,
    /// `ribbon:focus-left`; anything else (other schemes, unknown ids) is nil.
    static func action(for string: String) -> Action? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "ribbon" else { return nil }
        var parts = ([url.host ?? ""] + url.pathComponents).filter { !$0.isEmpty && $0 != "/" }
        if parts.isEmpty, let opaque = URL(string: string)?.absoluteString.dropFirst("ribbon:".count) {
            parts = opaque.split(separator: "/").map(String.init)
        }
        if parts.first == "command" { parts.removeFirst() }
        guard let name = parts.first?.lowercased(), parts.count == 1 else { return nil }
        switch name {
        case "enable": return .enable
        case "disable": return .disable
        case "relayout": return .relayout
        case "gather": return .gather
        case "settings": return .settings
        default: return Command(id: name).map(Action.command)
        }
    }
}
