import SwiftUI
import AppKit

struct FrontPage: View {
    let edition: Edition
    /// Height of the visible page, for sizing the lead picture.
    let pageHeight: CGFloat

    // All post-lead items flow through one masonry — secondaries first
    // (they carry images and summaries more often so anchor the top of
    // each column), briefs behind them. Shortest-column-wins distribution
    // keeps the page balanced; no more rigid briefs gutter with its own
    // whitespace budget.
    private var masonryItems: [FeedItem] {
        edition.secondaries + edition.briefs
    }

    /// The printed width of the page. Seeded at the widest the paper can be so
    /// the lead's standfirst is planned sensibly on its very first frame; the
    /// probe corrects it for a narrower window before anything is drawn twice.
    @State private var pageWidth: CGFloat = Paper.maxContentWidth

    var body: some View {
        VStack(spacing: 28) {
            // Zero-height, flexible-width probe. `Color.clear` takes what it
            // is offered and never asks for more, so measuring it cannot feed
            // back into the layout.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.width, initial: true) { _, new in
                            if new > 0 { pageWidth = new }
                        }
                    }
                )

            Masthead(date: edition.date)

            Rectangle().fill(Color.primary).frame(height: 3)

            if let lead = edition.lead {
                LeadStoryView(item: lead, width: pageWidth, pageHeight: pageHeight)
            }

            if !masonryItems.isEmpty {
                // Divider only when a lead sits above it; with no lead the
                // masthead's heavy rule already tops the columns.
                if edition.lead != nil {
                    Rectangle().fill(Color.primary.opacity(0.3)).frame(height: 1)
                }

                MasonryColumns(
                    items: masonryItems,
                    columns: 3,
                    spacing: 28,
                    estimateHeight: StoryCard.estimateHeight(_:columnWidth:)
                ) { item, width in
                    StoryCard(item: item, columnWidth: width)
                }
            }
        }
    }
}

private struct LeadStoryView: View {
    @Environment(AppStore.self) private var store
    let item: FeedItem
    /// The full printed width of the page. The lead spans it, which is exactly
    /// why its standfirst needs splitting into columns.
    let width: CGFloat
    /// Height of the visible page. The picture is capped as a share of it.
    let pageHeight: CGFloat

    /// How many lines of standfirst the lead gets, per column. Two columns of
    /// eight is about what the feeds supply: a stored standfirst runs to a
    /// median of 15–17 lines at a column's width.
    private static let summaryMaxLines = 8

    /// Live knobs. `leadHeroHeightFraction` retunes the picture's share of the
    /// page; `leadHeroMaxHeight` overrides it with an absolute cap in points,
    /// and 0 there removes the cap entirely. Both retune a running build via
    /// `defaults write cc.jorviksoftware.JorvikDailyNews …`. See `ImageCap` for
    /// where the share comes from.
    @AppStorage(ImageCap.leadKey) private var heroMaxHeight = ImageCap.leadUnset
    @AppStorage(ImageCap.leadFractionKey) private var heroFraction = ImageCap.leadHeightFractionDefault

    private var heroCap: CGFloat? {
        ImageCap.lead(pageHeight: pageHeight, override: heroMaxHeight, fraction: heroFraction)
    }

    private var isRead: Bool { store.readStore.isRead(item.itemId) }

    private var gutter: CGFloat { Standfirst.columnGutterDefault }
    private var halfWidth: CGFloat { (width - gutter) / 2 }

    /// Whether to set the lead across rather than down.
    ///
    /// A full-width picture stacked over a one-line standfirst leaves the whole
    /// right-hand measure empty and the deck reads as an afterthought. Turning
    /// it on its side — picture in one column, headline and deck in the other —
    /// fills the width with the same material.
    ///
    /// The trigger is the standfirst planner's own answer rather than a new
    /// threshold: if the deck is short enough to want a single column, it is
    /// short enough to sit beside the picture. There has to be a picture to sit
    /// beside, so a text-only lead stays stacked.
    private var setsAcross: Bool {
        guard item.imageURL != nil, !item.summary.isEmpty else { return false }
        let deck = Standfirst.plan(item.summary, width: width, metrics: .lead, maxLines: Self.summaryMaxLines)
        return deck.columns.filter { !$0.isEmpty }.count <= 1
    }

    var body: some View {
        Button {
            store.openArticle(item)
        } label: {
            if setsAcross {
                // Centred, not top-aligned. The two columns hold different
                // amounts — a picture that fills its half beside three lines of
                // text — and hanging the short one from the top leaves it
                // stranded above a well of white space. Centring reads as two
                // things placed together rather than one thing that ran out.
                HStack(alignment: .center, spacing: gutter) {
                    hero
                    VStack(alignment: .leading, spacing: 10) {
                        strap
                        headline
                        standfirst(width: halfWidth)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    hero
                    strap
                    headline
                    standfirst(width: width)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(isRead ? 0.55 : 1.0)
        .storySectionContextMenu(for: item)
    }

    @ViewBuilder
    private var hero: some View {
        if let img = item.imageURL {
            // If the lead's image can't actually load, demote it: a recompute
            // re-picks the next usable-image item as lead (or drops the lead).
            // `ImageCache` has already recorded the failure, so the builder
            // skips this one next time.
            OptionalImage(
                url: img,
                maxHeight: heroCap,
                onFailure: { store.recomputeVisibleEdition() }
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var strap: some View {
        Text(item.sourceTitle.uppercased())
            .font(.custom("Charter", size: 10))
            .kerning(1.8)
            .foregroundStyle(.secondary)
    }

    private var headline: some View {
        Text(item.displayTitle)
            .font(.custom("Didot", size: 38))
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func standfirst(width: CGFloat) -> some View {
        if !item.summary.isEmpty {
            StandfirstText(
                text: item.summary,
                width: width,
                metrics: .lead,
                maxLines: Self.summaryMaxLines
            )
        }
    }
}
