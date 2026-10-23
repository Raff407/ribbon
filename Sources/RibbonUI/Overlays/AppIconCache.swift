import AppKit
import RibbonCore
import UniformTypeIdentifiers

/// App icons for overlays and the Rules pane. Looks up the running app first
/// (`NSRunningApplication.icon`), then the app bundle by bundle id, then a generic
/// application icon. Main thread only.
final class AppIconCache {
    static let shared = AppIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private lazy var genericIcon: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    init() {
        cache.countLimit = 256
    }

    /// Icon for a window's app; never nil (falls back to the generic app icon).
    func icon(pid: ProcessID, bundleID: String?) -> NSImage {
        guard pid > 0 || bundleID != nil else { return genericIcon }
        let key = cacheKey(pid: pid, bundleID: bundleID)
        if let cached = cache.object(forKey: key) { return cached }
        let found = NSRunningApplication(processIdentifier: pid)?.icon ?? bundleIcon(bundleID)
        guard let icon = found else { return genericIcon }
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// Icon for an app by bundle id (installed or running); generic icon when unknown.
    func icon(bundleID: String) -> NSImage {
        let key = "bundle:\(bundleID)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        guard let icon = running ?? bundleIcon(bundleID) else { return genericIcon }
        cache.setObject(icon, forKey: key)
        return icon
    }

    private func bundleIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Bundle id when known (stable across relaunches), else the pid.
    private func cacheKey(pid: ProcessID, bundleID: String?) -> NSString {
        if let bundleID { return "bundle:\(bundleID)" as NSString }
        return "pid:\(pid)" as NSString
    }
}
