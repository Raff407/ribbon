import RibbonCore
import SwiftUI

public extension RibbonSettings {
    /// Returns a copy with the value at `keyPath` replaced (the original is untouched).
    func setting<Value>(_ keyPath: WritableKeyPath<RibbonSettings, Value>, to value: Value) -> RibbonSettings {
        var copy = self
        copy[keyPath: keyPath] = value
        return copy
    }
}

public extension SettingsStore {
    /// A SwiftUI binding to one nested setting. Every write produces a new
    /// `RibbonSettings` value (and is skipped when nothing changed, so sliders don't
    /// spam saves and engine updates with identical values).
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<RibbonSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.set(keyPath, to: $0) }
        )
    }

    /// Stores `value` at `keyPath` when it differs from the current one.
    func set<Value: Equatable>(_ keyPath: WritableKeyPath<RibbonSettings, Value>, to value: Value) {
        guard settings[keyPath: keyPath] != value else { return }
        settings = settings.setting(keyPath, to: value)
    }
}

extension Binding {
    /// A derived binding: reads through `get`, writes `set(newValue, current)` back.
    func map<T>(get: @escaping (Value) -> T, set: @escaping (T, Value) -> Value) -> Binding<T> {
        Binding<T>(
            get: { get(self.wrappedValue) },
            set: { self.wrappedValue = set($0, self.wrappedValue) }
        )
    }
}

extension Binding where Value == ModifierSet {
    /// Whether `member` is in the set; toggling inserts/removes it.
    func contains(_ member: ModifierSet) -> Binding<Bool> {
        map(
            get: { $0.contains(member) },
            set: { isOn, current in isOn ? current.union(member) : current.subtracting(member) }
        )
    }
}

extension Binding where Value == Double {
    /// Presents a 0...1 fraction as a 0...100 percentage.
    var percent: Binding<Double> {
        map(get: { $0 * 100 }, set: { newValue, _ in newValue / 100 })
    }
}
