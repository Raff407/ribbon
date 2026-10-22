import AppKit

/// Deep links into System Settings panes Ribbon points people at.
enum SystemSettingsLink: String, CaseIterable {
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case trackpad = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    /// Desktop & Dock: Stage Manager, Mission Control (rearrange Spaces, separate Spaces).
    case desktopAndDock = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    case loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    var url: URL? { URL(string: rawValue) }

    /// Opens the pane; logs (never throws) when the URL can't be opened.
    func open() {
        guard let url, NSWorkspace.shared.open(url) else {
            Log.settings.error("Could not open System Settings link \(self.rawValue, privacy: .public)")
            return
        }
    }
}
