import SwiftUI
import AppKit

struct SectionPageView: View {
    let page: SectionPage
    let date: Date
    let pageNumber: Int
    let totalPages: Int

    // Section pages cap story count so a busy feed can't produce a 100-item
    // page. Older items sit in the edition file for the archive browser.
    private let itemsCap = 24

    private var dateline: String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: date).uppercased()
    }

    private var itemsToShow: [FeedItem] {
        Array(page.items.prefix(itemsCap))
    }

    /// Rough height estimate for masonry distribution — keeps column lengths
    /// close enough without measuring. Tuned against the typographic sizes
    /// used in `SectionStoryCard`.
    static func estimateCardHeight(_ item: FeedItem) -> CGFloat {
        var h: CGFloat = 0
        if item.imageURL != nil { h += 170 }           // image + padding
        h += 14                                         // source strap
        h += min(CGFloat(item.title.count), 120) * 0.85 // title (wrapped)
        h += 18                                         // headline gap
        if !item.summary.isEmpty {
            let bodyChars = min(CGFloat(item.summary.count), 5 * 60)
            h += bodyChars / 60 * 22
        }
        return max(80, h)
    }

    var body: some View {
        VStack(spacing: 24) {
            // Section masthead
            VStack(spacing: 6) {
                HStack {
                    Text(dateline)
                        .font(.custom("Charter", size: 10))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Page \(pageNumber) of \(totalPages)")
                        .font(.custom("Charter", size: 10))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
                Text(page.name)
                    .font(.custom("Didot", size: 56))
                    .kerning(2)
            }
            Rectangle().fill(Color.primary).frame(height: 3)

            MasonryColumns(
                items: itemsToShow,
                columns: 2,
                spacing: 28,
                estimateHeight: Self.estimateCardHeight
            ) { item in
                SectionStoryCard(item: item)
            }

            if page.items.count > itemsCap {
                Text("\(page.items.count - itemsCap) more in archive")
                    .font(.custom("Charter", size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }
}

private struct SectionStoryCard: View {
    @Environment(AppStore.self) private var store
    let item: FeedItem

    private var isRead: Bool { store.readStore.isRead(item.itemId) }

    var body: some View {
        Button {
            store.openArticle(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let img = item.imageURL {
                    OptionalImage(url: img, height: 160)
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
}
