import Foundation
import Observation

/// Tracks which article itemIds the user has opened (clicked through to the
/// reader). Read state is a lightweight visual affordance only — no counts,
/// no badges, no filtering. The list persists across sessions so a
/// yesterday-read item stays marked if it resurfaces.
@Observable
@MainActor
final class ReadStore {
    private(set) var readIds: Set<String> = []
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
        self.storeURL = dir.appendingPathComponent("read.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let ids = try? JSONDecoder().decode([String].self, from: data) {
            readIds = Set(ids)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(readIds)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    func markRead(_ itemId: String) {
        guard !readIds.contains(itemId) else { return }
        readIds.insert(itemId)
        save()
    }

    func markUnread(_ itemId: String) {
        guard readIds.contains(itemId) else { return }
        readIds.remove(itemId)
        save()
    }

    /// Carries read marks across the change that namespaced item identities.
    ///
    /// An item's id used to be the guid a feed offered; it is now that guid
    /// hashed with the feed's own id, so every key in this file changed at
    /// once. Without this, every story in today's paper would come back
    /// unread on the first launch after the upgrade, and with
    /// `hideReadItems` on that is the whole paper reappearing.
    ///
    /// Only the items in hand can be migrated, because an old key cannot be
    /// turned back into a feed. That is enough: the paper is day-scoped, so a
    /// read mark for an item not in today's edition is already unreachable.
    ///
    /// Idempotent, and saves once rather than per item.
    func migrateLegacyIDs(for items: [FeedItem]) {
        var carried = 0
        for item in items {
            guard let legacy = item.legacyItemId, legacy != item.itemId,
                  readIds.contains(legacy), !readIds.contains(item.itemId)
            else { continue }
            readIds.insert(item.itemId)
            carried += 1
        }
        guard carried > 0 else { return }
        jdnLog("read: carried \(carried) read mark(s) onto namespaced item ids")
        save()
    }

    func isRead(_ itemId: String) -> Bool {
        readIds.contains(itemId)
    }

    func clearAll() {
        readIds = []
        save()
    }
}
