import SwiftUI

/// Reports each card's real laid-out height up to the masonry.
private struct HeightPreference<ID: Hashable>: PreferenceKey {
    static var defaultValue: [ID: CGFloat] { [:] }
    static func reduce(value: inout [ID: CGFloat], nextValue: () -> [ID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Masonry-style multi-column view. Items are distributed into `columns`
/// vertical stacks; each item joins whichever column is currently shortest.
/// Columns flow independently — no row-alignment whitespace between sibling
/// cards of different heights.
///
/// Distribution runs on MEASURED heights, not estimates. `estimateHeight` is
/// only the seed for the very first pass, before anything has been laid out;
/// after that each card reports its real height and the columns are
/// redistributed from those. An estimate can never be good enough on its own
/// here, because a card's height depends on how its text wraps and on a
/// picture that has not downloaded yet — and shortest-column-wins balances the
/// ESTIMATES exactly, so every bit of estimator error lands in the rendered
/// page as visible imbalance.
///
/// This converges. Every column is the same width, so a card's height does not
/// depend on which column it sits in: redistributing cannot change the heights
/// that drove the redistribution. Layout re-runs only when a height genuinely
/// changes, which in practice means a picture arriving.
///
/// The distribution is held in `@State` rather than recomputed on every body
/// pass, so it changes only at those moments and never mid-scroll.
struct MasonryColumns<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    /// First-pass seed only, used for items not yet measured.
    let estimateHeight: (Item, CGFloat) -> CGFloat
    @ViewBuilder let content: (Item) -> Content

    @State private var distributed: [[Item]] = []
    @State private var measured: [Item.ID: CGFloat] = [:]
    @State private var totalWidth: CGFloat = 0

    /// Ink colour for the separating rules — a hairline that reads clearly
    /// in both light and dark mode without shouting.
    private var ruleColor: Color { Color.primary.opacity(0.18) }

    /// One column's width. The HStack lays out `columns` columns, plus
    /// `columns - 1` hairline rules, each rule with a half-spacing gap on
    /// either side.
    private func columnWidth(for total: CGFloat) -> CGFloat {
        let rules = CGFloat(columns - 1)
        let gaps = rules * 2 * (spacing / 2)
        return max(0, (total - rules - gaps) / CGFloat(columns))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Zero-height probe spanning the full width. `Color.clear` with a
            // flexible width takes what it is offered and never asks for more,
            // so measuring it cannot feed back into the layout.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.width, initial: true) { _, new in
                            totalWidth = new
                            redistribute()
                        }
                    }
                )

            if distributed.count == columns {
                HStack(alignment: .top, spacing: spacing / 2) {
                    ForEach(0..<columns, id: \.self) { idx in
                        if idx > 0 {
                            // Continuous vertical rule spanning the full masonry
                            // height (a Rectangle stretched to the tallest column).
                            ruleColor
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                        column(idx)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onPreferenceChange(HeightPreference<Item.ID>.self) { heights in
            guard heights != measured else { return }
            measured = heights
            redistribute()
        }
        .onChange(of: items.map(\.id), initial: true) { _, _ in
            // A new item set invalidates every measurement.
            measured = [:]
            redistribute()
        }
    }

    /// Shortest-column-wins distribution, taken as a snapshot.
    private func redistribute() {
        guard totalWidth > 0 else { return }
        let width = columnWidth(for: totalWidth)
        var cols: [[Item]] = Array(repeating: [], count: columns)
        var heights = [CGFloat](repeating: 0, count: columns)
        for item in items {
            let idx = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            cols[idx].append(item)
            heights[idx] += (measured[item.id] ?? estimateHeight(item, width)) + spacing
        }
        distributed = cols
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
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: HeightPreference<Item.ID>.self,
                                value: [item.id: proxy.size.height]
                            )
                        }
                    )
            }
        }
    }
}
