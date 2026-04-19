import SwiftUI
import AppKit

/// One card shape used across the front page (below the lead) and every
/// section page. Image if one exists (natural aspect, no cropping), small-
/// caps source strap, Didot headline, 5-line summary. Read items render at
/// 55% opacity. Used inside `MasonryColumns` on both pages so the paper
/// balances its content automatically.
struct StoryCard: View {
    @Environment(AppStore.self) private var store
    let item: FeedItem

    private var isRead: Bool { store.readStore.isRead(item.itemId) }

    var body: some View {
        Button {
            store.openArticle(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let img = item.imageURL {
                    OptionalImage(url: img)
                        .padding(.bottom, 2)
                }
                Text(item.sourceTitle.uppercased())
                    .font(.custom("Charter", size: 9))
                    .kerning(1.5)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.custom("Didot", size: 20))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.custom("Charter", size: 12))
                        .lineSpacing(2)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(isRead ? 0.55 : 1.0)
    }

    /// Rough height estimate used by the masonry distributor. Doesn't need
    /// to be accurate — just good enough to keep columns balanced.
    static func estimateHeight(_ item: FeedItem) -> CGFloat {
        var h: CGFloat = 0
        if item.imageURL != nil { h += 240 }
        h += 14
        h += min(CGFloat(item.title.count), 120) * 0.85
        h += 18
        if !item.summary.isEmpty {
            let bodyChars = min(CGFloat(item.summary.count), 5 * 60)
            h += bodyChars / 60 * 22
        }
        return max(80, h)
    }
}
