import Foundation

struct EditionBuilder {
    // Front-page slot budgets, chosen so a quiet day still looks like a paper
    // and a busy day doesn't overfill the front.
    let secondariesCap = 3
    let briefsCap = 12

    func build(from items: [FeedItem], date: Date) -> Edition {
        // Daily News means: only items whose published date falls inside today
        // (local calendar). Older items never appear, even if they'd otherwise
        // rank highly — hence "Daily". Refreshes during the day pick up new
        // today-items as they publish.
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86_400)
        let todayOnly = items.filter { $0.publishedAt >= startOfDay && $0.publishedAt < endOfDay }
        // Dedupe by canonical link (multiple feeds often carry the same
        // article, e.g. Guardian main + Guardian football), then by itemId
        // as a fallback for feeds that share guids but not URLs.
        let deduped = dedupeByLink(todayOnly)
        let sorted = deduped.sorted { $0.publishedAt > $1.publishedAt }
        let interleaved = roundRobinByFeed(sorted)

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
        let sections = bySection
            .map { SectionPage(name: $0.key, items: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

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
    /// item. First-seen wins, preserving date ordering.
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
