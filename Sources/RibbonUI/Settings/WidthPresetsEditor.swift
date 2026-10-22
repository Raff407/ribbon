import SwiftUI

/// Pure edits of the cycle-width preset list (fractions of the working area).
enum WidthPresetEditing {
    /// Presets closer than this are treated as the same width.
    static let tolerance = 0.005
    static let percentRange: ClosedRange<Int> = 10...100

    static func contains(_ fraction: Double, in presets: [Double]) -> Bool {
        presets.contains { abs($0 - fraction) < tolerance }
    }

    /// The list with `fraction` added (sorted; unchanged when already present).
    static func adding(_ fraction: Double, to presets: [Double]) -> [Double] {
        guard fraction.isFinite, !contains(fraction, in: presets) else { return presets }
        return (presets + [fraction]).sorted()
    }

    /// The list without the preset at `index`; at least one preset always remains.
    static func removing(at index: Int, from presets: [Double]) -> [Double] {
        guard presets.count > 1, presets.indices.contains(index) else { return presets }
        return presets.enumerated().filter { $0.offset != index }.map(\.element)
    }
}

/// Percent chips for the width presets, with remove buttons and an "add" stepper.
struct WidthPresetsEditor: View {
    @Binding var presets: [Double]
    @State private var newPercent = 75

    var body: some View {
        LabeledContent {
            FlowLayout(spacing: 6, alignment: .trailing) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, fraction in
                    chip(index: index, fraction: fraction)
                }
            }
        } label: {
            RowLabel(title: "Width presets", detail: "Cycle width steps through these.")
        }
        LabeledContent("Add a preset") {
            HStack(spacing: 8) {
                Stepper(value: $newPercent, in: WidthPresetEditing.percentRange, step: 5) {
                    Text("\(newPercent)%").monospacedDigit()
                }
                Button("Add") { presets = WidthPresetEditing.adding(newFraction, to: presets) }
                    .disabled(WidthPresetEditing.contains(newFraction, in: presets))
            }
        }
    }

    private var newFraction: Double { Double(newPercent) / 100 }

    private func chip(index: Int, fraction: Double) -> some View {
        HStack(spacing: 4) {
            Text(ValueFormat.percent(fraction)).monospacedDigit()
            Button {
                presets = WidthPresetEditing.removing(at: index, from: presets)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(presets.count <= 1)
            .help("Remove this preset")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}
