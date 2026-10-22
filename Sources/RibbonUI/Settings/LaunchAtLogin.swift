import Combine
import Foundation
import ServiceManagement

/// Launch-at-login state backed by `SMAppService.mainApp` (macOS 13+). Errors are kept
/// as a user-facing message instead of being thrown, so the General pane can show them
/// inline. Main thread only.
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        self.status = service.status
    }

    /// On, or registered but waiting for the user's approval in System Settings.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    var needsApproval: Bool { status == .requiresApproval }

    /// Short description of the current state, nil when there's nothing to say.
    var statusText: String? {
        switch status {
        case .requiresApproval: return "Allow Ribbon in System Settings → General → Login Items."
        case .notFound: return "Login items need Ribbon to run from its app bundle."
        default: return nil
        }
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            Log.settings.error("Launch at login change failed: \(String(describing: error), privacy: .public)")
            errorMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
        refresh()
    }
}
