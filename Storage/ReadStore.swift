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

    convenience init() {
        self.init(directory: Self.supportDirectory())
    }

    /// The designated one, so a test can point at a directory of its own
    /// rather than the reader's real `read.json`.
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("read.json")
        load()
    }

    static func supportDirectory() -> URL {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("JorvikDailyNews", isDirectory: true)
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
    ///
    /// **A legacy key is consumed as it is carried.** `namespacedID` exists so
    /// no feed can name another feed's item, and `legacyItemId` is the raw
    /// guid, which is public — so a feed copying a guid out of another feed's
    /// XML could inherit its read mark, and could do it again at every launch
    /// while this file still held legacy keys. Removing the key means each one
    /// can be claimed exactly once, by whichever item reaches it first, and
    /// the file drains as the upgrade completes.
    ///
    /// Inheriting a read mark only hides the attacker's own item, which is
    /// harmless on its own. The pin half of the same trick, in
    /// `ArticleClassifier`, is not.
    ///
    /// **"Whichever item reaches it first" was decided by a date the feed
    /// writes.** Page order comes from `roundRobinByFeed`, seeded by first
    /// appearance in a date-descending list, so a feed dating its items to the
    /// present was `all[0]` and claimed every contested key — and because the
    /// key is then consumed, the genuine item could never claim it on any
    /// later launch either. So a contested key is awarded to nobody: two items
    /// offering one guid is evidence of a copy, not of a migration.
    @discardableResult
    func migrateLegacyIDs(for items: [FeedItem]) -> Bool {
        var carried = 0
        let uncontested = FeedItem.uncontestedLegacyKeys(in: items)
        for item in items {
            guard let legacy = item.legacyItemId, legacy != item.itemId,
                  uncontested.contains(legacy),
                  readIds.contains(legacy), !readIds.contains(item.itemId)
            else { continue }
            readIds.insert(item.itemId)
            readIds.remove(legacy)
            carried += 1
        }
        // Whether there was anything to migrate at all, which is not the same
        // question as whether anything was carried. `onLaunch` recomputes once
        // against the PREVIOUS build's edition before the first refresh, and
        // that edition has no `legacyItemId` on any item, so the latch was
        // burned by a pass that could not have done anything.
        let hadLegacyKeys = items.contains { $0.legacyItemId != nil }
        guard carried > 0 else { return hadLegacyKeys }
        jdnLog("read: carried \(carried) read mark(s) onto namespaced item ids")
        save()
        return true
    }

    func isRead(_ itemId: String) -> Bool {
        readIds.contains(itemId)
    }

    func clearAll() {
        readIds = []
        save()
    }
}
