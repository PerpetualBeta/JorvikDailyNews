import Foundation

/// Read marks and pins carried across the 1.5.0 identity change.
///
/// `namespacedID` exists so no feed can name another feed's item. The raw
/// guid is kept beside it as `legacyItemId` only so a reader's marks survive
/// the upgrade — and a guid is public, printed in the feed XML. So the
/// migration is the one place where the old, forgeable identity still decides
/// anything, and it has to be a one-shot.
enum LegacyIDTests {

    @MainActor
    private static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jdn-legacy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func item(_ itemId: String, legacy: String, feed: UUID = UUID()) -> FeedItem {
        FeedItem(feedId: feed, itemId: itemId, title: "A story",
                 link: URL(string: "https://example.com/\(itemId)")!,
                 summary: "Words.", imageURL: nil, publishedAt: Date(),
                 section: "News", sourceTitle: "fixture", legacyItemId: legacy)
    }

    /// `main.swift` is a nonisolated top-level context and both stores are
    /// `@MainActor`. It really is the main thread, so say so rather than
    /// spawning a task the runner would not wait for.
    static func run() {
        MainActor.assumeIsolated { runOnMain() }
    }

    @MainActor
    private static func runOnMain() {
        T.suite("Legacy ids: a read mark can be claimed once") {
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ReadStore(directory: dir)
            store.markRead("tag:bbc.co.uk,2026:story-1")

            // The genuine item arrives and inherits the mark.
            store.migrateLegacyIDs(for: [item("hash-real", legacy: "tag:bbc.co.uk,2026:story-1")])
            T.expect(store.isRead("hash-real"), "the first item to ask gets it")

            // A second feed offering the same guid — copied out of the first
            // feed's public XML — finds nothing left to claim.
            store.migrateLegacyIDs(for: [item("hash-copy", legacy: "tag:bbc.co.uk,2026:story-1")])
            T.expect(!store.isRead("hash-copy"), "a copied guid cannot claim it again")
            T.expect(!store.isRead("tag:bbc.co.uk,2026:story-1"), "and the old key is gone")
        }

        T.suite("Legacy ids: a pin can be claimed once") {
            // This is the half that pays: a pin puts an item on a section page
            // the reader curated.
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let classifier = ArticleClassifier(directory: dir)
            classifier.move(itemId: "guid-from-their-feed", text: "Markets and money.",
                            to: "Business")

            classifier.migrateLegacyIDs(for: [item("hash-real", legacy: "guid-from-their-feed")])
            T.equal(classifier.pinnedSection(itemId: "hash-real"), "Business",
                    "the genuine item keeps its section")

            classifier.migrateLegacyIDs(for: [item("hash-copy", legacy: "guid-from-their-feed")])
            T.expect(classifier.pinnedSection(itemId: "hash-copy") == nil,
                     "a copied guid cannot be pinned onto the reader's page")
            T.expect(classifier.pinnedSection(itemId: "guid-from-their-feed") == nil,
                     "and the old key is gone")
        }

        T.suite("Legacy ids: an ordinary upgrade is unaffected") {
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ReadStore(directory: dir)
            let ids = (0..<20).map { "https://example.com/story-\($0)" }
            for id in ids { store.markRead(id) }
            store.migrateLegacyIDs(for: ids.enumerated().map {
                item("hash-\($0.offset)", legacy: $0.element)
            })
            for index in 0..<20 {
                T.expect(store.isRead("hash-\(index)"), "mark \(index) carried")
            }
        }
    }
}
