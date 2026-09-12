import Foundation

/// Every case here is a fault that shipped, not a hypothetical.
///
/// The fetch layer had no tests until 2026-09-09, and four bugs had been in it
/// since it was written: items above a parse error discarded, an HTML page
/// counting as a healthy feed, RSS 1.0 dropped item by item, and two root
/// checks disagreeing with each other. None was reported by a user. All four
/// are pure functions of bytes, which is the most testable shape code comes
/// in, and the reason they went unnoticed is that nothing could call this
/// without a network and a user interface.
enum FeedFetcherTests {
    private static func feed(_ url: String = "https://example.com/feed.xml") -> Feed {
        Feed(url: URL(string: url)!, section: "News", title: "fixture")
    }

    static func run() {
        T.suite("RSS 2.0: the ordinary case") {
            let out = try FeedFetcher.parse(T.fixture("rss2-minimal.xml"), from: feed())
            T.equal(out.title, "Minimal RSS 2.0", "channel title")
            T.equal(out.items.count, 2, "item count")
            T.equal(out.items.first?.title, "First story", "first title")
            T.equal(out.items.first?.link.absoluteString, "https://example.com/first", "first link")
            // The entity must be decoded, not passed through as markup.
            T.expect(out.items.contains { $0.title.contains("&") }, "ampersand decoded in a title")
            T.expect(!out.items.contains { $0.title.contains("&amp;") }, "no raw entity left in a title")
        }

        T.suite("Atom 1.0: link comes from an attribute") {
            let out = try FeedFetcher.parse(T.fixture("atom-minimal.xml"), from: feed())
            T.equal(out.title, "Minimal Atom 1.0", "feed title")
            T.equal(out.items.count, 2, "entry count")
            // rel="alternate" and a bare href must both resolve; Atom carries
            // the link as an attribute where RSS carries it as element text.
            T.equal(out.items.first?.link.absoluteString, "https://example.com/atom-one", "rel=alternate href")
            T.expect(out.items.contains { $0.link.absoluteString == "https://example.com/atom-two" },
                     "bare href with no rel")
        }

        T.suite("RSS 1.0: root is rdf:RDF") {
            // Shipped broken since the app was written. The root is `rdf:RDF`,
            // which matched neither flavour test, so `<link>` was never read
            // and every item was rejected for having no http link: ten items
            // built, ten discarded, and nothing logged because `emptyFeed` is
            // declared and never thrown.
            let out = try FeedFetcher.parse(T.fixture("rss1-rdf.xml"), from: feed())
            T.expect(out.items.count >= 5, "items survive an RDF root (got \(out.items.count))")
            T.expect(out.items.allSatisfy { $0.link.scheme?.hasPrefix("http") == true },
                     "every item has an http link")
            T.expect(out.items.allSatisfy { !$0.title.isEmpty }, "every item has a title")
        }

        T.suite("A page where a feed should be") {
            // FeedBurner serves an ordinary web page for a retired feed, and
            // an HTML page is well-formed enough that XMLParser accepts it. It
            // used to be recorded as a healthy fetch containing no items, so a
            // dead subscription looked exactly like a quiet blog.
            do {
                let out = try FeedFetcher.parse(T.fixture("not-a-feed.html"), from: feed())
                T.expect(false, "an HTML page must not parse as a feed (got \(out.items.count) items)")
            } catch let error as FeedFetchError {
                guard case .notAFeed(let root) = error else {
                    T.expect(false, "expected .notAFeed, got \(error)")
                    return
                }
                T.expect(root.lowercased().contains("html"), "names the root element (got \(root))")
            }
        }

        T.suite("Malformed partway: keep what parsed") {
            // Nine items parse cleanly and the parser then dies on an
            // unterminated CDATA 726 lines in. Returning nil threw all nine
            // away and the log described the feed as simply dead.
            let out = try FeedFetcher.parse(T.fixture("malformed-cdata.xml"), from: feed())
            T.expect(out.items.count >= 5, "items above the fault are kept (got \(out.items.count))")
            T.expect(out.items.allSatisfy { !$0.title.isEmpty },
                     "no half-built item leaks through")
        }

        T.suite("Valid but empty") {
            // A real feed with no items yet. It must not be an error, and it
            // must not be mistaken for a page that is not a feed.
            let out = try FeedFetcher.parse(T.fixture("empty-but-valid.xml"), from: feed())
            T.equal(out.items.count, 0, "no items")
            T.equal(out.title, "A feed with nothing in it", "title still read")
        }

        T.suite("Dates: a feed cannot stamp itself into the future") {
            // There used to be a five-minute allowance for clock skew, and it
            // was worth more to an attacker than to a publisher: `now + 4m59s`
            // survived untouched and is strictly greater than every honestly
            // dated item, so the feed led the date-descending sort on every
            // refresh for free.
            let now = Date()
            T.equal(FeedFetcher.clamped(now.addingTimeInterval(299), now: now), now,
                    "four minutes fifty-nine ahead is pulled back")
            T.equal(FeedFetcher.clamped(now.addingTimeInterval(86_400), now: now), now,
                    "and so is tomorrow")
            let past = now.addingTimeInterval(-3600)
            T.equal(FeedFetcher.clamped(past, now: now), past, "an honest date is left alone")
            T.equal(FeedFetcher.clamped(now, now: now), now, "and so is one dated this second")

            // Clamping to `now` still handed the feed the top of every
            // date-descending sort, on every refresh. A feed cannot honestly
            // publish something later than the last time this reader read it.
            let lastFetch = now.addingTimeInterval(-3600)
            T.equal(FeedFetcher.clamped(now.addingTimeInterval(86_400), now: now, since: lastFetch),
                    lastFetch, "a future date falls back to the last successful fetch")
            T.equal(FeedFetcher.clamped(past, now: now, since: lastFetch), past,
                    "an honest date is still untouched")
            // An item published since that fetch is dated honestly and still
            // beats the restamped one.
            let fresh = now.addingTimeInterval(-60)
            T.expect(FeedFetcher.clamped(fresh, now: now, since: lastFetch) > lastFetch,
                     "so a genuinely fresh item still sorts above it")
            T.equal(FeedFetcher.clamped(now.addingTimeInterval(86_400), now: now), now,
                    "a feed never read before still clamps to now")
        }
    }
}
