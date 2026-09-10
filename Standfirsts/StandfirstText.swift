import SwiftUI

/// Draws a standfirst fitted to the space it has, in as many columns as its
/// measure warrants.
///
/// Nothing here sets `lineLimit`. That is the point: `lineLimit` clips the
/// *rendering*, which lands the ellipsis wherever the line happens to break,
/// usually mid-word. This cuts the *content* instead — `Standfirst.plan` hands
/// back text already measured to fit, ending on a finished sentence — so there
/// is nothing left to truncate and no ellipsis to place.
///
/// The cost of that is a measurement, which needs a width. Callers pass one
/// rather than a `GeometryReader` reading it back, because a card that renders
/// empty on its first frame and fills in on its second makes the masonry
/// redistribute twice on every page turn.
struct StandfirstText: View {
    let text: String
    let width: CGFloat
    let metrics: Standfirst.Metrics
    let maxLines: Int

    var body: some View {
        let plan = Standfirst.plan(text, width: width, metrics: metrics, maxLines: maxLines)
        let filled = plan.columns.filter { !$0.isEmpty }
        let columnWidth = (width - plan.gutter * CGFloat(plan.columns.count - 1))
            / CGFloat(max(1, plan.columns.count))

        HStack(alignment: .top, spacing: plan.gutter) {
            ForEach(Array(filled.enumerated()), id: \.offset) { _, column in
                Text(column)
                    .font(.custom(metrics.fontName, size: metrics.size))
                    .lineSpacing(metrics.lineSpacing)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // An EXPLICIT width, and the plan's own, because the text
                    // was measured against exactly this number. Sharing the
                    // space out instead looked equivalent and was not: a deck
                    // short enough to fill one column of two leaves the other
                    // empty, an empty `Text` claims nothing, and the survivor
                    // spread across the whole measure — back to the 113
                    // characters a line the columns exist to prevent. This is
                    // safe where a measured width would not be: it is computed
                    // from the width we were handed, not read back from the
                    // layout, so there is no loop to close.
                    .frame(width: columnWidth, alignment: .topLeading)
            }
            // Hold the remaining columns' worth of space open, so a short deck
            // sits in its column with white space beside it rather than
            // re-centring under the headline.
            if filled.count < plan.columns.count {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
