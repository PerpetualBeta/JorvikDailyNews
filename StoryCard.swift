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
    /// The masonry column this card landed in. Needed before the first frame,
    /// because the standfirst is measured to fit it.
    let columnWidth: CGFloat

    /// Live knob. `defaults write cc.jorviksoftware.JorvikDailyNews
    /// cardImageMaxHeight -float 300` retunes every card picture on a running
    /// build; 0 removes the cap. See `ImageCap` for where 260 comes from.
    @AppStorage(ImageCap.cardKey) private var imageMaxHeight = ImageCap.cardDefault

    /// How many lines of standfirst a card gets. The text is cut to this,
    /// not clipped to it, so a card always ends on a finished sentence.
    static let summaryMaxLines = 5

    /// A card's share of the stored standfirst, measured to its own column.
    ///
    /// `Standfirst.extract` sizes every item for the lead, because any item can
    /// be promoted there when the paper reflows. A card cuts that back to what
    /// actually fits five lines of its column, ending on a finished sentence.
    static func plan(for item: FeedItem, columnWidth: CGFloat) -> Standfirst.Plan {
        Standfirst.plan(item.summary, width: columnWidth, metrics: .card, maxLines: summaryMaxLines)
    }

    private var isRead: Bool { store.readStore.isRead(item.itemId) }

    var body: some View {
        Button {
            store.openArticle(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let img = item.imageURL {
                    OptionalImage(url: img, maxHeight: ImageCap.resolve(imageMaxHeight))
                        .padding(.bottom, 2)
                }
                Text(item.sourceTitle.uppercased())
                    .font(.custom("Charter", size: 9))
                    .kerning(1.5)
                    .foregroundStyle(.secondary)
                Text(item.displayTitle)
                    .font(.custom("Didot", size: 20))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.summary.isEmpty {
                    StandfirstText(
                        text: item.summary,
                        width: columnWidth,
                        metrics: .card,
                        maxLines: Self.summaryMaxLines
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(isRead ? 0.55 : 1.0)
        .storySectionContextMenu(for: item)
    }

    /// Height estimate used by the masonry distributor to choose which column
    /// an item joins. It reserves no space, so a poor estimate only makes the
    /// columns uneven — it never leaves a gap.
    static func estimateHeight(_ item: FeedItem, columnWidth: CGFloat) -> CGFloat {
        var h = imageHeight(item, columnWidth: columnWidth)
        h += 14
        h += min(CGFloat(item.title.count), 120) * 0.85
        h += 18
        // The seed measures what the card will actually draw. It was a
        // characters-per-line approximation before the standfirst was laid out
        // to fit; now that the real layout is already computed and cached,
        // guessing at it would be strictly worse and no cheaper.
        if !item.summary.isEmpty {
            h += Standfirst.height(of: plan(for: item, columnWidth: columnWidth), width: columnWidth, metrics: .card)
        }
        return max(80, h)
    }

    /// What the picture will contribute, mirroring `OptionalImage`: never
    /// upscaled past its own pixels, then height-capped.
    ///
    /// Once the picture is decoded this is exact, because we know its real
    /// aspect. Before that we assume the cap — the upper bound, applied
    /// identically to every unknown picture so they stay comparable. That is
    /// why the distribution is snapshot rather than live: the answer here
    /// sharpens as pictures arrive, and items must not hop columns while the
    /// reader is looking at them.
    private static func imageHeight(_ item: FeedItem, columnWidth: CGFloat) -> CGFloat {
        guard let url = item.imageURL, columnWidth > 0 else { return 0 }
        let cap = ImageCap.card
        guard let img = ImageCache.shared.cachedImage(for: url),
              img.size.width > 0, img.size.height > 0
        else { return cap ?? columnWidth }
        // No `displayScale` environment outside a View; the main screen's
        // backing factor is right for an estimate.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = CGFloat(img.representations.map(\.pixelsWide).max() ?? Int(img.size.width))
        let drawn = min(columnWidth, pixels / scale)
        let natural = drawn * img.size.height / img.size.width
        return min(natural, cap ?? natural)
    }
}

/// Right-click "Move to…" menu shared by every card on the paper. Lists
/// known sections (current one ticked), plus a "New section…" option that
/// opens an alert to create one on the fly. Each pick trains the
/// classifier, pins the article, and reflows the visible edition.
extension View {
    func storySectionContextMenu(for item: FeedItem) -> some View {
        modifier(StorySectionContextMenu(item: item))
    }
}

private struct StorySectionContextMenu: ViewModifier {
    @Environment(AppStore.self) private var store
    let item: FeedItem
    @State private var promptOpen = false
    @State private var newSectionName = ""

    func body(content: Content) -> some View {
        content.contextMenu {
            let current = store.classifier.pinnedSection(itemId: item.itemId) ?? item.section
            ForEach(store.allSections, id: \.self) { section in
                if section == current {
                    Label(section, systemImage: "checkmark")
                } else {
                    Button("Move to \(section)") {
                        store.moveArticle(item, to: section)
                    }
                }
            }
            Divider()
            Button("New section\u{2026}") {
                newSectionName = ""
                promptOpen = true
            }
            if let host = store.displayHost(for: item) {
                Divider()
                Button("Exclude \(host)") {
                    store.excludeSource(item)
                }
            }
        }
        .alert(
            "Move to new section",
            isPresented: $promptOpen
        ) {
            TextField("Section name", text: $newSectionName)
            Button("Move") {
                let trimmed = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { store.moveArticle(item, to: trimmed) }
                promptOpen = false
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { promptOpen = false }
        } message: {
            Text("Move \u{201C}\(item.title)\u{201D} to a new section. The paper learns from this correction.")
        }
    }
}
