import Foundation

struct EditionBuilder {
    /// How many stories fit on one section page.
    ///
    /// Sixty, against a front page of sixteen plus a lead, so a section page
    /// is a long read rather than an endless one: twenty per column in the
    /// three-column masonry. The number that matters is the one it replaces,
    /// which was unbounded and produced a 505-item page.
    ///
    /// Tunable live, because the right figure is a matter of how it feels to
    /// turn a page and that cannot be settled by arithmetic:
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews sectionPageCap -int 96
    ///
    /// Read with `object(forKey:) as? Int` so an unset key keeps the default:
    /// `integer(forKey:)` answers 0 for a missing key, which here would mean
    /// a page holding nothing.
    static var sectionPageCap: Int {
        let stored = UserDefaults.standard.object(forKey: "sectionPageCap") as? Int
        guard let stored, stored > 0 else { return sectionPageCapDefault }
        return stored
    }
    static let sectionPageCapDefault = 60

    /// The span of local time an edition covers.
    ///
    /// Exposed rather than inlined because a refresh has to report how many of
    /// the items it fetched were even eligible, and deriving that boundary a
    /// second time at the call site would give the app two definitions of
    /// "today" that could drift apart. There is one, and it lives here.
    static func dayRange(for date: Date) -> Range<Date> {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return start..<end
    }

    // Front-page slot budgets, chosen so a quiet day still looks like a paper
    // and a busy day doesn't overfill the front.
    let secondariesCap = 3
    let briefsCap = 12

    func build(from items: [FeedItem], date: Date) -> Edition {
        // Daily News means: only items whose published date falls inside today
        // (local calendar). Older items never appear, even if they'd otherwise
        // rank highly — hence "Daily". Refreshes during the day pick up new
        // today-items as they publish.
        let today = Self.dayRange(for: date)
        let todayOnly = items.filter { today.contains($0.publishedAt) }
        // Sort BEFORE deduping, not after. `dedupeByLink` keeps whichever
        // copy it meets first, so the order it is handed decides which of two
        // syndicated copies reaches the page — and un-sorted, that order is
        // the completion order of 16 concurrent fetches, which is a race.
        // Two feeds carrying one article (Guardian main + Guardian football)
        // could therefore yield a different paper on each refresh, and the
        // copies are not interchangeable: one may have been enriched with a
        // picture and a standfirst and the other not.
        //
        // Sorted first, "first seen" means "newest", every time.
        let sorted = todayOnly.sorted { $0.publishedAt > $1.publishedAt }
        // Dedupe by canonical link, then by itemId as a fallback for feeds
        // that share guids but not URLs.
        let deduped = dedupeByLink(sorted)
        let interleaved = roundRobinByFeed(deduped)

        // The lead *must* display an image — a text-only hero looks like a
        // mistake at full-width span. An item qualifies only if it has an
        // image URL that isn't already known to have failed to load (a 404'd
        // og:image, a dead host, etc. — `ImageCache` records these as they
        // fail at render). Round-robin biases ordering by recency + diversity,
        // so `.first(where:)` picks the newest usable-image item from the
        // strongest feed. If none qualify, drop the lead entirely (lead = nil)
        // and let every item flow into the 3 columns instead.
        var remaining = interleaved
        // Prefer an item that can carry BOTH halves of a lead, then either half,
        // then anything at all. The front page always has a lead now.
        //
        // It used to fall to nil when nothing had a usable picture, on the
        // grounds that a text-only hero looks like a mistake at full-width
        // span. That was true when the alternative was a bare headline over
        // white space. It is no longer: a lead with no picture is now a
        // full-width headline over a two-column deck, which reads as a paper
        // with no art today rather than as something that failed.
        //
        // Dropping the lead was also the wrong failure mode for the reason it
        // usually fired. `hasUsableImage` consults `ImageCache`, so a moment of
        // throttling that marks pictures unusable took the whole lead with it
        // and left a front page that opened on a column of small headlines.
        // Losing the picture is a fair consequence of a bad cache. Losing the
        // lead is not.
        let candidate = remaining.first(where: { Self.canAnchorLead($0) })
            ?? remaining.first(where: { Self.hasUsableImage($0) })
            ?? remaining.first(where: { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? remaining.first
        let lead: FeedItem?
        if let candidate, let idx = remaining.firstIndex(of: candidate) {
            lead = candidate
            remaining.remove(at: idx)
        } else {
            // Only when there is nothing in the paper at all.
            lead = nil
        }

        let secondaries = Array(remaining.prefix(secondariesCap))
        remaining = Array(remaining.dropFirst(secondaries.count))
        let briefs = Array(remaining.prefix(briefsCap))
        remaining = Array(remaining.dropFirst(briefs.count))
        let leftover = remaining
        let bySection = Dictionary(grouping: leftover) { $0.section }
        // A section page used to be "everything left over", with no cap, so a
        // busy News section put **505 items on one page**. Every card in the
        // masonry publishes its height through a `GeometryReader` and every
        // height change triggers a redistribute, so 505 of them is a
        // measure-and-relayout storm on the main thread: the page took
        // seconds to open and spun the beachball while it did.
        //
        // A newspaper page has an extent. An oversized section becomes several
        // pages of the same name, which the page title renders as
        // "News (2 of 9)", and which is what a broadsheet does anyway.
        let sections = bySection
            .map { (name: $0.key, items: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .flatMap { section -> [SectionPage] in
                stride(from: 0, to: section.items.count, by: Self.sectionPageCap).map { start in
                    let end = min(start + Self.sectionPageCap, section.items.count)
                    return SectionPage(name: section.name, items: Array(section.items[start..<end]))
                }
            }

        return Edition(
            date: Calendar.current.startOfDay(for: date),
            publishedAt: Date(),
            lead: lead,
            secondaries: secondaries,
            briefs: briefs,
            sections: sections
        )
    }

    /// An item can anchor the full-width lead only if it has an image URL we
    /// haven't already seen fail to load (`ImageCache` records failures as
    /// they happen at render). A merely-slow image still qualifies — only a
    /// confirmed failure disqualifies it.
    /// An item fit to anchor the lead: a usable picture and something to read
    /// under the headline.
    static func canAnchorLead(_ item: FeedItem) -> Bool {
        hasUsableImage(item) && !item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasUsableImage(_ item: FeedItem) -> Bool {
        guard let url = item.imageURL else { return false }
        return !ImageCache.shared.isFailed(url)
    }

    /// Remove items that share a canonical link or itemId with an earlier
    /// item, preserving the order given.
    ///
    /// First seen wins, so the caller's ordering IS the tie-break rule. It is
    /// handed a date-sorted list for exactly that reason.
    private func dedupeByLink(_ items: [FeedItem]) -> [FeedItem] {
        var seenLinks = Set<String>()
        var seenIds = Set<String>()
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            let linkKey = item.link.absoluteString.lowercased()
            if seenLinks.contains(linkKey) { continue }
            if seenIds.contains(item.itemId) { continue }
            seenLinks.insert(linkKey)
            seenIds.insert(item.itemId)
            result.append(item)
        }
        return result
    }

    /// Round-robin across feeds so no single source dominates the front page.
    /// Feed order is seeded by first-seen (i.e. whichever feed has the newest
    /// item goes first); within each feed, items stay in date-desc order.
    private func roundRobinByFeed(_ items: [FeedItem]) -> [FeedItem] {
        var buckets: [UUID: [FeedItem]] = [:]
        var order: [UUID] = []
        for item in items {
            if buckets[item.feedId] == nil {
                buckets[item.feedId] = []
                order.append(item.feedId)
            }
            buckets[item.feedId]!.append(item)
        }

        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        while buckets.values.contains(where: { !$0.isEmpty }) {
            for feedId in order {
                if let bucket = buckets[feedId], !bucket.isEmpty {
                    result.append(bucket[0])
                    buckets[feedId] = Array(bucket.dropFirst())
                }
            }
        }
        return result
    }
}
