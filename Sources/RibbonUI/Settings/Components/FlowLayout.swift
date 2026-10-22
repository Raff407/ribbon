import SwiftUI

/// Lays children out left to right, wrapping onto new rows when the proposed width runs
/// out (chips, shortcut buttons). macOS 13 `Layout` protocol.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(maxWidth: bounds.width, subviews: subviews) {
            var x = startX(for: row, in: bounds)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let origin = CGPoint(x: x, y: y + (row.height - size.height) / 2)
                subviews[index].place(at: origin, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func startX(for row: Row, in bounds: CGRect) -> CGFloat {
        switch alignment {
        case .trailing: return bounds.maxX - row.width
        case .center: return bounds.midX - row.width / 2
        default: return bounds.minX
        }
    }

    /// Greedy row breaking; a child wider than the row gets a row of its own.
    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current = Row(indices: current.indices + [index], width: added, height: max(current.height, size.height))
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
