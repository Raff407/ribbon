import Foundation
import RibbonCore

/// Pulls loaded settings back into the ranges the UI offers, so a hand-edited or
/// corrupted preference can't produce a broken layout (or, worse, an empty scroll
/// modifier set that would swallow every scroll event).
///
/// Pure: works on copies (so fields added to RibbonCore later pass through untouched).
enum SettingsSanitizer {
    /// Ranges shared with the settings panes.
    enum Range {
        static let gap: ClosedRange<Double> = 0...40
        static let outerGap: ClosedRange<Double> = 0...60
        static let widthFraction: ClosedRange<Double> = 0.1...1
        static let step: ClosedRange<Double> = 0.05...0.5
        static let animationSpeed: ClosedRange<Double> = 0.5...3
        static let sensitivity: ClosedRange<Double> = 0.25...3
        static let borderWidth: ClosedRange<Double> = 1...12
        static let cornerRadius: ClosedRange<Double> = 0...24
        static let dimAmount: ClosedRange<Double> = 0...0.8
        static let indicatorDuration: ClosedRange<Double> = 0.3...5
        static let swipeFingers: ClosedRange<Int> = 3...4
    }

    static func sanitized(_ settings: RibbonSettings) -> RibbonSettings {
        var copy = settings
        copy.layout = sanitized(settings.layout)
        copy.animation.speed = clamp(settings.animation.speed, Range.animationSpeed, fallback: 1)
        copy.appearance = sanitized(settings.appearance)
        copy.trackpad = sanitized(settings.trackpad)
        return copy
    }

    private static func sanitized(_ layout: LayoutConfig) -> LayoutConfig {
        let defaults = LayoutConfig.default
        let presets = layout.widthPresets
            .filter { $0.isFinite && Range.widthFraction.contains($0) }
            .sorted()
        var copy = layout
        copy.gap = clamp(layout.gap, Range.gap, fallback: defaults.gap)
        copy.outerGap = clamp(layout.outerGap, Range.outerGap, fallback: defaults.outerGap)
        copy.widthPresets = presets.isEmpty ? defaults.widthPresets : presets
        copy.defaultWidthFraction = clamp(layout.defaultWidthFraction, Range.widthFraction,
                                          fallback: defaults.defaultWidthFraction)
        copy.widthStep = clamp(layout.widthStep, Range.step, fallback: defaults.widthStep)
        copy.heightStep = clamp(layout.heightStep, Range.step, fallback: defaults.heightStep)
        return copy
    }

    private static func sanitized(_ appearance: AppearanceSettings) -> AppearanceSettings {
        let defaults = AppearanceSettings()
        var copy = appearance
        copy.focusBorderWidth = clamp(appearance.focusBorderWidth, Range.borderWidth,
                                      fallback: defaults.focusBorderWidth)
        if ColorHex.parse(appearance.focusBorderColorHex) == nil {
            copy.focusBorderColorHex = defaults.focusBorderColorHex
        }
        copy.focusBorderCornerRadius = clamp(appearance.focusBorderCornerRadius, Range.cornerRadius,
                                             fallback: defaults.focusBorderCornerRadius)
        copy.dimAmount = clamp(appearance.dimAmount, Range.dimAmount, fallback: defaults.dimAmount)
        copy.indicatorDuration = clamp(appearance.indicatorDuration, Range.indicatorDuration,
                                       fallback: defaults.indicatorDuration)
        return copy
    }

    private static func sanitized(_ trackpad: TrackpadSettings) -> TrackpadSettings {
        var copy = trackpad
        if trackpad.scrollModifiers.isEmpty { copy.scrollModifiers = .hyperLite }
        copy.swipeFingers = min(max(trackpad.swipeFingers, Range.swipeFingers.lowerBound),
                                Range.swipeFingers.upperBound)
        copy.sensitivity = clamp(trackpad.sensitivity, Range.sensitivity, fallback: 1)
        return copy
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
