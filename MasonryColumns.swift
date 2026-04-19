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

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { idx in
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(distributed[idx]) { item in
                        content(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
