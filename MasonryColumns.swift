import SwiftUI

/// Simple masonry-style multi-column view. Items are distributed into
/// `columns` vertical stacks; for each item we pick the column with the
/// shortest accumulated estimated height. Each column flows independently —
/// no row-alignment whitespace between sibling cards of different heights.
struct MasonryColumns<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    let estimateHeight: (Item) -> CGFloat
    @ViewBuilder let content: (Item) -> Content

    private var distributed: [[Item]] {
        var cols: [[Item]] = Array(repeating: [], count: columns)
        var heights: [CGFloat] = Array(repeating: 0, count: columns)
        for item in items {
            let idx = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            cols[idx].append(item)
            heights[idx] += estimateHeight(item) + spacing
        }
        return cols
    }

    /// Ink colour for the separating rules — a hairline that reads clearly
    /// in both light and dark mode without shouting.
    private var ruleColor: Color { Color.primary.opacity(0.18) }

    var body: some View {
        // Half-spacing on each side of a rule keeps the original column gap
        // (e.g. 28 → 14 + rule + 14) with the line centred in it.
        HStack(alignment: .top, spacing: spacing / 2) {
            ForEach(0..<columns, id: \.self) { idx in
                if idx > 0 {
                    // Continuous vertical rule spanning the full masonry height
                    // (a Rectangle stretched to the tallest column).
                    ruleColor
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
                column(idx)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func column(_ idx: Int) -> some View {
        VStack(alignment: .leading, spacing: spacing / 2) {
            ForEach(Array(distributed[idx].enumerated()), id: \.element.id) { offset, item in
                if offset > 0 {
                    // Horizontal rule between stacked cards, centred in the gap.
                    ruleColor.frame(height: 1)
                }
                content(item)
            }
        }
    }
}
