import SwiftUI

/// Title plus an optional secondary line, System Settings style.
struct RowLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch row with an optional explanation underneath the title.
struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { RowLabel(title: title, detail: detail) }
    }
}

/// A labelled slider with the formatted current value on the right.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                slider
                    .labelsHidden()
                    .frame(minWidth: 140, maxWidth: 260)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step) { Text(title) }
        } else {
            Slider(value: $value, in: range) { Text(title) }
        }
    }
}

/// Secondary explanatory text inside a form section.
struct HelpText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A ✓ / ⚠ status line.
struct StatusLine: View {
    let isOK: Bool
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isOK ? .green : .orange)
        }
        .font(.callout)
    }
}

/// Number formatting shared by the panes.
enum ValueFormat {
    static func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func multiplier(_ value: Double) -> String { String(format: "%.1f×", value) }
    static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
}
