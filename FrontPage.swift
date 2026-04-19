import SwiftUI
import AppKit

struct FrontPage: View {
    let edition: Edition

    var body: some View {
        VStack(spacing: 28) {
            Masthead(date: edition.date)

            Rectangle().fill(Color.primary).frame(height: 3)

            if let lead = edition.lead {
                HStack(alignment: .top, spacing: 32) {
                    LeadStoryView(item: lead)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BriefsColumn(items: edition.briefs)
                        .frame(width: 240)
                }
            }

            if !edition.secondaries.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.3)).frame(height: 1)

                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(edition.secondaries.enumerated()), id: \.element.itemId) { index, item in
                        if index > 0 {
                            Rectangle().fill(Color.primary.opacity(0.2))
                                .frame(width: 1)
                                .padding(.vertical, 4)
                        }
                        SecondaryStoryView(item: item)
                    }
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
                    OptionalImage(url: img, height: 280)
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

private struct SecondaryStoryView: View {
    @Environment(AppStore.self) private var store
    let item: FeedItem

    private var isRead: Bool { store.readStore.isRead(item.itemId) }

    var body: some View {
        Button {
            store.openArticle(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let img = item.imageURL {
                    OptionalImage(url: img, height: 140)
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

private struct BriefsColumn: View {
    @Environment(AppStore.self) private var store
    let items: [FeedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("IN BRIEF")
                .font(.custom("Charter", size: 11))
                .kerning(2.5)
                .padding(.bottom, 8)
            Rectangle().fill(Color.primary).frame(height: 2)
            ForEach(items, id: \.itemId) { item in
                Button {
                    store.openArticle(item)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.custom("Charter", size: 13))
                            .fontWeight(.semibold)
                            .lineSpacing(2)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.sourceTitle.uppercased())
                            .font(.custom("Charter", size: 8))
                            .kerning(1.2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .opacity(store.readStore.isRead(item.itemId) ? 0.55 : 1.0)
                Rectangle().fill(Color.primary.opacity(0.2)).frame(height: 0.5)
            }
        }
    }
}
