import SwiftUI
import AppKit

struct FrontPage: View {
    let edition: Edition

    // All post-lead items flow through one masonry — secondaries first
    // (they carry images and summaries more often so anchor the top of
    // each column), briefs behind them. Shortest-column-wins distribution
    // keeps the page balanced; no more rigid briefs gutter with its own
    // whitespace budget.
    private var masonryItems: [FeedItem] {
        edition.secondaries + edition.briefs
    }

    var body: some View {
        VStack(spacing: 28) {
            Masthead(date: edition.date)

            Rectangle().fill(Color.primary).frame(height: 3)

            if let lead = edition.lead {
                LeadStoryView(item: lead)
            }

            if !masonryItems.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.3)).frame(height: 1)

                MasonryColumns(
                    items: masonryItems,
                    columns: 3,
                    spacing: 28,
                    estimateHeight: StoryCard.estimateHeight
                ) { item in
                    StoryCard(item: item)
                }
            }
        }
    }
}

private struct LeadStoryView: View {
    @Environment(AppStore.self) private var store
    let item: FeedItem

    private var isRead: Bool { store.readStore.isRead(item.itemId) }

    var body: some View {
        Button {
            store.openArticle(item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                if let img = item.imageURL {
                    OptionalImage(url: img)
                }
                Text(item.sourceTitle.uppercased())
                    .font(.custom("Charter", size: 10))
                    .kerning(1.8)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.custom("Didot", size: 38))
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.custom("Charter", size: 14))
                        .lineSpacing(4)
                        .lineLimit(8)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(isRead ? 0.55 : 1.0)
    }
}
