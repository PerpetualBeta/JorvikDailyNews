import Foundation

/// Every quantity a feed controls used to be unbounded: how many items, how
/// long a title, how long a summary, how much text in one element, and how far
/// an internal entity could be amplified. All of them are written into files
/// that are rewritten on every refresh.
enum FeedBoundsTests {

    private static let feed = Feed(url: URL(string: "https://example.com/feed.xml")!,
                                   section: "News", title: nil)

    private static func parse(_ xml: String) throws -> FetchedFeed {
        try FeedFetcher.parse(Data(xml.utf8), from: feed)
    }

    /// `doctype` goes between the declaration and the root, which is the only
    /// place an internal DTD may appear. Building it here rather than
    /// concatenating at the call site, because doing that by hand produced a
    /// document with TWO xml declarations and a parser error that looked like
    /// a fault in the guard under test.
    private static func rss(_ inner: String, channelTitle: String = "A feed",
                            doctype: String = "") -> String {
        "<?xml version=\"1.0\"?>\n" + doctype
            + "<rss><channel><title>\(channelTitle)</title>\(inner)</channel></rss>"
    }

    private static func item(_ title: String, summary: String = "A description.",
                             link: String = "https://example.com/a") -> String {
        "<item><title>\(title)</title><link>\(link)</link>"
            + "<description>\(summary)</description></item>"
    }

    static func run() {
        T.suite("Bounds: the entity guard cannot be walked past") {
            func bomb(prolog: String = "", encoding: String.Encoding = .utf8) -> Data {
                let xml = "<?xml version=\"1.0\"?>\n" + prolog
                       + "<!DOCTYPE rss [<!ENTITY a \"" + String(repeating: "x", count: 4000) + "\">]>"
                       + "<rss><channel><title>&a;</title></channel></rss>"
                return xml.data(using: encoding) ?? Data()
            }
            // The shape that used to work: a comment long enough to push the
            // declaration past the old 256 KB window. XML's prolog allows
            // comments of any length before the DOCTYPE.
            let padding = "<!--" + String(repeating: "p", count: 300 * 1024) + "-->\n"
            func refused(_ data: Data) -> Bool {
                do { _ = try FeedFetcher.parse(data, from: feed); return false }
                catch { return true }
            }
            T.expect(refused(bomb(prolog: padding)),
                     "a 300 KB comment before the DOCTYPE no longer hides it")
            T.expect(refused(bomb()), "and the plain case still refuses")
            // The other shape: the same document in UTF-16, where the ASCII
            // marker matched nothing while XMLParser decoded it happily.
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf16] {
                T.expect(refused(bomb(encoding: encoding)), "refused in \(encoding)")
            }
            T.expect(refused(bomb(prolog: padding, encoding: .utf16)), "and both together")
            // An ordinary feed must still pass, in either encoding.
            let plain = "<?xml version=\"1.0\"?><rss><channel><title>Ordinary</title></channel></rss>"
            for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
                T.expect(!refused(plain.data(using: encoding) ?? Data()),
                         "an ordinary feed passes in \(encoding)")
            }
        }

        T.suite("Bounds: an entity bomb is refused before parsing") {
            // 1 MB entity, 100,000 references, from a 1.5 MB file. Measured at
            // 61.69s before this guard and 0.00s after. Scaled down here so
            // the suite stays quick; the shape is what matters.
            let big = String(repeating: "A", count: 4096)
            let bomb = rss(item(String(repeating: "&big;", count: 2000)),
                           doctype: "<!DOCTYPE rss [ <!ENTITY big \"\(big)\"> ]>\n")
            let started = Date()
            do {
                _ = try parse(bomb)
                T.expect(false, "an oversized internal entity must be refused")
            } catch {
                T.expect(true, "refused")
            }
            T.expect(Date().timeIntervalSince(started) < 1.0, "and refused promptly")
        }

        T.suite("Bounds: a feed that declares nbsp still works") {
            // XML predefines only five entities, so a feed wanting &nbsp; MUST
            // declare it, and real feeds do. Refusing internal entities
            // outright would have broken them.
            let legit = rss(item("A story&nbsp;with a space"),
                            doctype: "<!DOCTYPE rss [ <!ENTITY nbsp \"&#160;\"> ]>\n")
            let out = try parse(legit)
            T.equal(out.items.count, 1, "the item survives")
            T.expect(out.items.first?.title.contains("story") == true, "and its title")
            T.expect(out.items.first?.title.contains("&nbsp;") == false,
                     "with the entity resolved, not left as markup")
        }

        T.suite("Bounds: items per feed") {
            let many = (1...(FeedFetcher.maxItemsPerFeed + 200))
                .map { item("Story \($0)", link: "https://example.com/\($0)") }
                .joined()
            let out = try parse(rss(many))
            T.expect(out.items.count <= FeedFetcher.maxItemsPerFeed,
                     "capped at \(FeedFetcher.maxItemsPerFeed), got \(out.items.count)")
            T.expect(out.items.count > 0, "and it is a cap, not a rejection")
        }

        T.suite("Bounds: a title is a title") {
            let out = try parse(rss(item(String(repeating: "A", count: 50_000))))
            T.equal(out.items.first?.title.count, FeedFetcher.maxStoredTitle,
                    "clamped to \(FeedFetcher.maxStoredTitle)")
        }

        T.suite("Bounds: a summary has a ceiling") {
            let body = String(repeating: "<p>alpha beta gamma delta epsilon zeta eta theta.</p>",
                              count: 4000)
            let out = try parse(rss(item("A story", summary: body
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;"))))
            let summary = out.items.first?.summary ?? ""
            T.expect(summary.count <= FeedFetcher.maxStoredSummary,
                     "at most \(FeedFetcher.maxStoredSummary), got \(summary.count)")
        }

        T.suite("Bounds: the channel title is persisted, so it is capped hardest") {
            // This one is written into feeds.json and rewritten on every
            // refresh, so an unbounded value is a permanent cost. Measured
            // before the cap: a 200 MB title parsed as a SUCCESS in 0.18s and
            // took 1.5 GB of resident memory with it.
            let out = try parse(rss(item("A story"),
                                    channelTitle: String(repeating: "T", count: 200_000)))
            T.expect((out.title.count) <= FeedFetcher.maxStoredTitle,
                     "clamped to \(FeedFetcher.maxStoredTitle), got \(out.title.count)")
        }

        T.suite("Bounds: an ordinary feed is unaffected") {
            let out = try parse(rss(item("Harry Kane nominated for the Ballon d'Or",
                                         summary: "The England captain is one of thirty "
                                                + "names on the list announced today.")))
            T.equal(out.items.count, 1, "one item")
            T.equal(out.title, "A feed", "channel title intact")
            T.equal(out.items.first?.title, "Harry Kane nominated for the Ballon d'Or",
                    "title intact, not clamped")
            T.expect(out.items.first?.summary.contains("thirty") == true, "summary intact")
        }
    }
}
