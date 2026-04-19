import Foundation

struct EditionBuilder {
    // Front-page slot budgets, chosen so a quiet day still looks like a paper
    // and a busy day doesn't overfill the front.
    let secondariesCap = 3
    let briefsCap = 8

    func build(from items: [FeedItem], date: Date) -> Edition {
        let sorted = items.sorted { $0.publishedAt > $1.publishedAt }
        let interleaved = roundRobinByFeed(sorted)

        // Lead must have an image whenever one is available anywhere in the
        // queue. Round-robin already biases ordering by recency + diversity,
        // so `.first(where:)` naturally picks the newest image-bearing item
        // from the strongest available feed. Fall back to the outright newest
        // only when every item is text-only.
        var remaining = interleaved
        let lead: FeedItem?
        if let imageBearing = remaining.first(where: { $0.imageURL != nil }),
           let idx = remaining.firstIndex(of: imageBearing) {
            lead = imageBearing
            remaining.remove(at: idx)
        } else {
            lead = remaining.first
            if !remaining.isEmpty { remaining.removeFirst() }
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
