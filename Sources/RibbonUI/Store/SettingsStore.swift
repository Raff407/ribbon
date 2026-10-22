import Combine
import Foundation
import RibbonCore

/// Owns the persisted RibbonSettings (UserDefaults, JSON under `key`). Every change is
/// saved immediately and published; the app subscribes and pushes it to the engine.
///
/// Main thread only (it backs SwiftUI views).
public final class SettingsStore: ObservableObject {
    @Published public var settings: RibbonSettings {
        didSet {
            guard settings != oldValue else { return }
            persist(settings)
        }
    }

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "RibbonSettings.v1") {
        self.defaults = defaults
        self.key = key
        // Property observers don't run during init, so loading never re-saves.
        settings = Self.load(from: defaults, key: key)
    }

    public func resetToDefaults() { settings = .defaults }

    /// Replaces the settings with `transform(settings)` (immutable update style).
    public func update(_ transform: (RibbonSettings) -> RibbonSettings) {
        settings = transform(settings)
    }

    // MARK: - Persistence

    /// Suffix of the key that keeps a copy of stored data that failed to decode, so a
    /// bad release can't silently destroy someone's configuration.
    static let unreadableSuffix = ".unreadable"

    static func load(from defaults: UserDefaults, key: String) -> RibbonSettings {
        guard let data = defaults.data(forKey: key) else { return .defaults }
        do {
            let decoded = try JSONDecoder().decode(RibbonSettings.self, from: data)
            return SettingsSanitizer.sanitized(decoded)
        } catch {
            Log.settings.error("Stored settings unreadable, using defaults: \(String(describing: error), privacy: .public)")
            defaults.set(data, forKey: key + unreadableSuffix)
            return .defaults
        }
    }

    private func persist(_ value: RibbonSettings) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            Log.settings.error("Could not save settings: \(String(describing: error), privacy: .public)")
        }
    }
}
