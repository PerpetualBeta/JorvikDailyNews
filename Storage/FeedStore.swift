import Foundation
import Observation

@Observable
@MainActor
final class FeedStore {
    private(set) var feeds: [Feed] = []
    private let storeURL: URL

    init() {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("JorvikDailyNews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("feeds.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        feeds = (try? JSONDecoder().decode([Feed].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Append a feed to the list, ignoring it if a feed with the same
    /// normalised URL is already present. Returns true if the feed was
    /// added, false if it was a duplicate.
    @discardableResult
    func add(_ feed: Feed) -> Bool {
        let key = Self.normalisedKey(feed.url)
        guard !feeds.contains(where: { Self.normalisedKey($0.url) == key }) else {
            return false
        }
        feeds.append(feed)
        save()
        return true
    }

    /// URL-comparison key for dedup. Lowercases scheme/host and strips a
    /// single trailing slash so `https://example.com/feed/` and
    /// `https://example.com/feed` are treated as the same feed.
    private static func normalisedKey(_ url: URL) -> String {
        var s = url.absoluteString.lowercased()
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func remove(_ feed: Feed) {
        feeds.removeAll { $0.id == feed.id }
        save()
    }

    func updateTitle(feedId: UUID, title: String) {
        guard let idx = feeds.firstIndex(where: { $0.id == feedId }) else { return }
        guard feeds[idx].title != title else { return }
        feeds[idx].title = title
        save()
    }

    func updateURL(feedId: UUID, url: URL) {
        guard let idx = feeds.firstIndex(where: { $0.id == feedId }) else { return }
        guard feeds[idx].url != url else { return }
        feeds[idx].url = url
        save()
    }

    func updateLastSeen(feedId: UUID, ids: [String]) {
        guard let idx = feeds.firstIndex(where: { $0.id == feedId }) else { return }
        feeds[idx].lastSeenItemIds = ids
        save()
    }

    func setPaused(feedId: UUID, paused: Bool) {
        guard let idx = feeds.firstIndex(where: { $0.id == feedId }) else { return }
        guard feeds[idx].isPaused != paused else { return }
        feeds[idx].isPaused = paused
        save()
    }

    func setSection(feedId: UUID, section: String) {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = feeds.firstIndex(where: { $0.id == feedId }) else { return }
        guard feeds[idx].section != trimmed else { return }
        feeds[idx].section = trimmed
        save()
    }

    /// Bulk import: appends feeds whose URL isn't already in the store
    /// **and** isn't a duplicate of an earlier candidate within the same
    /// batch. The inner `seen` set is what makes the within-batch dedup
    /// work — a 300-feed OPML that lists Hacker News three times under
    /// different categories now adds it once, not three times.
    /// Returns the (addedCount, skippedCount) for caller feedback.
    @discardableResult
    func importFeeds(_ candidates: [Feed]) -> (added: Int, skipped: Int) {
        var seen = Set(feeds.map { Self.normalisedKey($0.url) })
        var added = 0
        var skipped = 0
        for candidate in candidates {
            let key = Self.normalisedKey(candidate.url)
            if seen.contains(key) {
                skipped += 1
                continue
            }
            seen.insert(key)
            feeds.append(candidate)
            added += 1
        }
        if added > 0 { save() }
        return (added, skipped)
    }

    /// Mark a feed as having just succeeded a fetch. Updates the
    /// successful-fetch timestamp and clears the failure timestamp so the
    /// status pill flips back to green even if the feed had been red.
    func recordFetchSuccess(feedId: UUID, at date: Date = Date()) {
        guard let idx = feeds.firstIndex(where: { $0.id == feedId }) else { return }
        feeds[idx].lastSuccessfulFetchAt = date
        feeds[idx].lastFailedFetchAt = nil
        save()
    }

    /// Mark a feed as having just failed a fetch. Updates the failure
    /// timestamp; leaves the last-successful timestamp alone so the pill
    /// can colour amber (recent failure with a recent prior success) vs
    /// red (failed > 30 days, or never succeeded).
    func recordFetchFailure(feedId: UUID, at date: Date = Date()) {
        guard let idx = feeds.firstIndex(where: { $0.id == feedId }) else { return }
        feeds[idx].lastFailedFetchAt = date
        save()
    }
}
