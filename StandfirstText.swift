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
        HStack(alignment: .top, spacing: plan.gutter) {
            ForEach(Array(plan.columns.enumerated()), id: \.offset) { _, column in
                Text(column)
                    .font(.custom(metrics.fontName, size: metrics.size))
                    .lineSpacing(metrics.lineSpacing)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Columns take an equal share of whatever they are offered.
                    // Never an explicit width: handing a measured width back
                    // into a frame is what collapses an HStack.
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
