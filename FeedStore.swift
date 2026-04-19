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

    func add(_ feed: Feed) {
        feeds.append(feed)
        save()
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

    /// Bulk import: appends feeds whose URL isn't already in the store.
    /// Returns the (addedCount, skippedCount) for caller feedback.
    @discardableResult
    func importFeeds(_ candidates: [Feed]) -> (added: Int, skipped: Int) {
        let existingURLs = Set(feeds.map { $0.url.absoluteString.lowercased() })
        var added = 0
        var skipped = 0
        for candidate in candidates {
            let key = candidate.url.absoluteString.lowercased()
            if existingURLs.contains(key) {
                skipped += 1
                continue
            }
            feeds.append(candidate)
            added += 1
        }
        if added > 0 { save() }
        return (added, skipped)
    }
}
