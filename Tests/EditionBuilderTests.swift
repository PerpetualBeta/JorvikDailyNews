import Foundation

/// The builder decides what a reader sees and, more to the point, what they do
/// not. Everything it drops it drops silently, which is why two of the cases
/// here are faults that reached a shipped paper: a section page of 505 items,
/// and a day boundary computed two different ways in two places.
enum EditionBuilderTests {

    static func run() {
        T.suite("Edition: the day's paper has a ceiling") {
            // performRefresh carries every prior item forward with no cap, and
            // nothing downstream imposes one: sections paginate rather than
            // truncate, and dedupe collapses only identical links or ids —
            // both feed-chosen. A feed serving 500 items an hour with a fresh
            // ?r= grows the edition all day.
            let now = Date()
            let many = (0..<(EditionBuilder.maxEditionItems + 500)).map {
                item("Item \($0)", at: now.addingTimeInterval(-Double($0)),
                     link: "https://e.com/a?r=\($0)")
            }
            let edition = EditionBuilder().build(from: many, date: Date())
            let total = edition.sections.reduce(0) { $0 + $1.items.count }
                      + (edition.lead == nil ? 0 : 1)
            T.expect(total <= EditionBuilder.maxEditionItems,
                     "capped, got \(total)")
            // An ordinary day is untouched.
            let ordinary = (0..<300).map {
                item("Item \($0)", at: now.addingTimeInterval(-Double($0)),
                     link: "https://e.com/b?r=\($0)")
            }
            let small = EditionBuilder().build(from: ordinary, date: Date())
            let smallTotal = small.sections.reduce(0) { $0 + $1.items.count }
                           + (small.lead == nil ? 0 : 1)
            T.expect(smallTotal > 250, "300 items come through, got \(smallTotal)")
        }

        T.suite("Edition: one feed cannot spend the whole day's budget") {
            // The cap used to be a plain prefix of a date-descending sort, and
            // the date is a string the feed wrote. One feed serving its 500
            // per fetch, each stamped at the top of the allowed range, took
            // every slot — and this runs BEFORE the round-robin, so the
            // diversity that would otherwise limit it never saw what was
            // dropped. `performRefresh` then carries the survivors forward
            // each hour.
            let now = Date()
            let loud = UUID()
            let hostile = (0..<(EditionBuilder.maxEditionItems + 1000)).map {
                item("Loud \($0)", at: now.addingTimeInterval(-Double($0) / 1000),
                     link: "https://loud.example/a?r=\($0)", feedId: loud)
            }
            // Ten genuine feeds, all dated an hour ago, so every one of them
            // loses on date to every hostile item.
            var genuine: [FeedItem] = []
            for feed in 0..<10 {
                let id = UUID()
                genuine += (0..<20).map {
                    item("Real \(feed)-\($0)", at: now.addingTimeInterval(-3600),
                         link: "https://real\(feed).example/a?r=\($0)", feedId: id)
                }
            }
            let kept = EditionBuilder.capped((hostile + genuine)
                .sorted { $0.publishedAt > $1.publishedAt })
            T.equal(kept.count, EditionBuilder.maxEditionItems, "the ceiling still holds")
            T.equal(kept.filter { $0.feedId != loud }.count, 200,
                    "and all 200 genuine items survive it")

            // A quiet day is untouched: under the ceiling, nothing is taken.
            let small = (0..<300).map {
                item("Item \($0)", at: now.addingTimeInterval(-Double($0)),
                     link: "https://e.com/c?r=\($0)")
            }
            T.equal(EditionBuilder.capped(small).count, 300, "300 items pass through whole")
        }

        T.suite("Publisher: compared on hosts, not on a name the feed chose") {
            let now = Date()
            // Both sides of this test used to be attacker-supplied: it matched
            // the link's host against the feed's own declared channel title.
            let spoof = item("Copied headline", at: now,
                             link: "https://www.bbc.co.uk/news/story",
                             sourceTitle: "BBC News", feedHost: "attacker.example")
            T.expect(!EditionBuilder.publishesItsOwn(spoof),
                     "calling yourself BBC News no longer makes you the BBC")

            let real = item("Real headline", at: now,
                            link: "https://www.bbc.co.uk/news/story",
                            sourceTitle: "anything at all", feedHost: "feeds.bbc.co.uk")
            T.expect(EditionBuilder.publishesItsOwn(real),
                     "a feed on the same domain is the publisher, whatever it calls itself")

            // The old label test took the second-to-last, so every .co.uk host
            // gave "co" and failed its own three-character minimum.
            T.equal(EditionBuilder.registrable("www.bbc.co.uk"), "bbc.co.uk", "a two-label suffix")
            T.equal(EditionBuilder.registrable("feeds.bbc.co.uk"), "bbc.co.uk", "and a deeper one")
            T.equal(EditionBuilder.registrable("www.ft.com"), "ft.com", "an ordinary suffix")
            T.equal(EditionBuilder.registrable("bbc.co.uk.evil.com"), "evil.com",
                    "a host that only looks like one")

            let lookalike = item("Copied headline", at: now,
                                 link: "https://www.bbc.co.uk/news/story",
                                 feedHost: "bbc.co.uk.evil.com")
            T.expect(!EditionBuilder.publishesItsOwn(lookalike), "so it is not preferred")

            let old = item("From an older edition", at: now,
                           link: "https://www.bbc.co.uk/news/story", feedHost: nil)
            T.expect(!EditionBuilder.publishesItsOwn(old),
                     "an item saved before the field existed declines to prefer")
        }

        T.suite("Publisher: a platform is not a publisher") {
            // Every tenant of a hosting suffix used to read as the same
            // publisher, so an attacker's Substack satisfied publishesItsOwn
            // against another Substack's links — and the log recorded the
            // substitution as a legitimate preference.
            T.equal(EditionBuilder.registrable("attacker.substack.com"),
                    "attacker.substack.com", "a Substack is its own publisher")
            T.expect(EditionBuilder.registrable("attacker.substack.com")
                     != EditionBuilder.registrable("victim.substack.com"),
                     "and two of them are not the same one")
            for host in ["github.io", "blogspot.com", "wordpress.com", "medium.com",
                         "pages.dev", "netlify.app", "amazonaws.com"] {
                T.expect(EditionBuilder.registrable("a." + host)
                         != EditionBuilder.registrable("b." + host),
                         "two tenants of \(host) are different publishers")
            }
            // Ordinary hosts are unchanged.
            T.equal(EditionBuilder.registrable("www.bbc.co.uk"), "bbc.co.uk", "a ccTLD suffix")
            T.equal(EditionBuilder.registrable("www.ft.com"), "ft.com", "and a plain one")
        }

        T.suite("Publisher: a feed served off the publisher's domain") {
            // The common case, not the exception: 52 of the 60 items in the
            // reader's own paper are served from a host that is not the
            // article's. Neither side can earn the preference, so the tie-break
            // never fires and first-met wins.
            let now = Date()
            let victim = item("Genuine headline", at: now.addingTimeInterval(-600),
                              link: "https://sixcolors.com/post/2026/09/a-story/",
                              feedHost: "feedpress.me")
            T.expect(!EditionBuilder.publishesItsOwn(victim),
                     "a FeedBurner-style victim cannot earn the preference either")
            // Which is why the date clamp is the load-bearing guard here, and
            // it is tested in FeedFetcherTests.
        }

        T.suite("Edition: the budget's unit is the publisher, not the subscription") {
            // feedId is one per subscription URL, and nothing caps how many
            // subscriptions one host may hold: an OPML file may carry 5,000
            // distinct paths on one host, which is 5,000 feed ids.
            let now = Date()
            var items: [FeedItem] = []
            for n in 0..<300 {
                let id = UUID()
                items += (0..<30).map {
                    item("Loud \(n)-\($0)", at: now.addingTimeInterval(-Double($0) / 100),
                         link: "https://loud.example/\(n)/a?r=\($0)", feedId: id,
                         feedHost: "loud.example")
                }
            }
            var genuine: [FeedItem] = []
            for n in 0..<10 {
                let id = UUID()
                genuine += (0..<20).map {
                    item("Real \(n)-\($0)", at: now.addingTimeInterval(-3600),
                         link: "https://real\(n).example/a?r=\($0)", feedId: id,
                         feedHost: "real\(n).example")
                }
            }
            let kept = EditionBuilder.capped((items + genuine)
                .sorted { $0.publishedAt > $1.publishedAt })
            T.equal(kept.filter { $0.feedHost != "loud.example" }.count, 200,
                    "300 subscriptions on one host do not evict the genuine feeds")
        }

        T.suite("Edition: the leftover slots are shared out too") {
            // share * feeds <= maxEditionItems by integer division, so pass
            // one can never fill the edition and pass two always runs. It used
            // to take a date-ordered prefix, so the feed that dated its items
            // latest took every remaining slot.
            let now = Date()
            var hostile: [FeedItem] = []
            let loud = UUID()
            for n in 0..<8000 {
                hostile.append(item("Loud \(n)", at: now.addingTimeInterval(-Double(n) / 10000),
                                    link: "https://loud.example/a?r=\(n)", feedId: loud,
                                    feedHost: "loud.example"))
            }
            var genuine: [FeedItem] = []
            for n in 0..<40 {
                let id = UUID()
                genuine += (0..<60).map {
                    item("Real \(n)-\($0)", at: now.addingTimeInterval(-3600 - Double($0)),
                         link: "https://real\(n).example/a?r=\($0)", feedId: id,
                         feedHost: "real\(n).example")
                }
            }
            let kept = EditionBuilder.capped((hostile + genuine)
                .sorted { $0.publishedAt > $1.publishedAt })
            T.equal(kept.count, EditionBuilder.maxEditionItems, "the ceiling holds")
            let survivors = kept.filter { $0.feedHost != "loud.example" }.count
            T.equal(survivors, 2400, "every genuine article survives")
            T.expect(kept.filter { $0.feedHost == "loud.example" }.count < 4000,
                     "and the loud feed does not take the rest of the paper")
        }

        T.suite("Day range: one day, half open") {
            let noon = date("2026-09-09 12:00")
            let range = EditionBuilder.dayRange(for: noon)
            T.expect(range.contains(noon), "noon is in its own day")
            T.expect(range.contains(date("2026-09-09 00:00")), "midnight starts the day")
            T.expect(range.contains(date("2026-09-09 23:59")), "one minute to midnight is still in it")
            // Half open at the top, or an item at exactly midnight belongs to
            // two days and gets built into both papers.
            T.expect(!range.contains(date("2026-09-10 00:00")), "the next midnight is excluded")
            T.expect(!range.contains(date("2026-09-08 23:59")), "yesterday is excluded")
        }

        T.suite("Only today's items are built") {
            let today = date("2026-09-09 12:00")
            let items = [
                item("today one",  at: date("2026-09-09 09:00")),
                item("today two",  at: date("2026-09-09 10:00")),
                item("yesterday",  at: date("2026-09-08 23:00")),
                item("tomorrow",   at: date("2026-09-10 01:00"))
            ]
            let edition = EditionBuilder().build(from: items, date: today)
            let titles = all(edition).map(\.title)
            T.equal(titles.count, 2, "two items survive the day filter")
            T.expect(!titles.contains("yesterday"), "yesterday is not in today's paper")
            T.expect(!titles.contains("tomorrow"), "a future timestamp is not either")
        }

        T.suite("Dedupe: same link, first seen wins") {
            // Syndicated stories arrive from several feeds at once, and the
            // same story twice on one page reads as a bug to a reader.
            let today = date("2026-09-09 12:00")
            let link = "https://example.com/story"
            let items = [
                item("earlier", at: date("2026-09-09 09:00"), link: link),
                item("later",   at: date("2026-09-09 10:00"), link: link.uppercased()),
                item("other",   at: date("2026-09-09 11:00"), link: "https://example.com/other")
            ]
            let titles = all(EditionBuilder().build(from: items, date: today)).map(\.title)
            T.equal(titles.count, 2, "the duplicate link is dropped")
            // Sorted newest first, so "later" is seen before "earlier".
            T.expect(titles.contains("later"), "the newer copy is kept")
            T.expect(!titles.contains("earlier"), "the older copy is not")
        }

        T.suite("Dedupe: the winner cannot depend on arrival order") {
            // This is the case the suite was written for and the one that was
            // broken. Dedupe ran before the sort, so which copy of a
            // syndicated story reached the page was decided by whichever of
            // 16 concurrent fetches finished first. The two copies are not
            // interchangeable — one may carry a picture and a standfirst and
            // the other not — so the paper could differ between refreshes for
            // no reason a reader could see.
            let today = date("2026-09-09 12:00")
            let link = "https://example.com/syndicated"
            let a = item("older", at: date("2026-09-09 09:00"), link: link)
            let b = item("newer", at: date("2026-09-09 10:00"), link: link)
            for (n, order) in [[a, b], [b, a]].enumerated() {
                let titles = all(EditionBuilder().build(from: order, date: today)).map(\.title)
                T.equal(titles, ["newer"], "arrival order \(n) yields the newer copy")
            }
        }

        T.suite("Dedupe: same itemId across feeds") {
            let today = date("2026-09-09 12:00")
            let items = [
                item("one", at: date("2026-09-09 09:00"), link: "https://a.example/x", itemId: "guid-1"),
                item("two", at: date("2026-09-09 10:00"), link: "https://b.example/y", itemId: "guid-1")
            ]
            T.equal(all(EditionBuilder().build(from: items, date: today)).count, 1,
                    "a shared guid is a duplicate even at different links")
        }

        T.suite("Round robin: one loud feed cannot own the paper") {
            // A feed publishing 30 items an hour would otherwise take every
            // slot above the fold by date alone.
            let today = date("2026-09-09 12:00")
            let loud = UUID(), quiet = UUID()
            var items: [FeedItem] = []
            for i in 0..<10 {
                items.append(item("loud \(i)", at: date("2026-09-09 11:00")
                    .addingTimeInterval(TimeInterval(-i)), feedId: loud))
            }
            items.append(item("quiet", at: date("2026-09-09 08:00"), feedId: quiet))
            let ordered = all(EditionBuilder().build(from: items, date: today)).map(\.title)
            guard let quietAt = ordered.firstIndex(of: "quiet") else {
                T.expect(false, "the quiet feed's item is in the paper")
                return
            }
            T.expect(quietAt <= 1, "the quiet feed reaches position \(quietAt), not last")
        }

        T.suite("Section pages are capped") {
            // Uncapped, a busy section built one page holding 505 items, and
            // laying that out is what produced the beach-ball.
            let today = date("2026-09-09 12:00")
            let cap = EditionBuilder.sectionPageCap
            let total = cap * 2 + 10
            var items: [FeedItem] = []
            for i in 0..<total {
                items.append(item("story \(i)", at: date("2026-09-09 11:00")
                    .addingTimeInterval(TimeInterval(-i)),
                    link: "https://example.com/\(i)", feedId: UUID()))
            }
            let edition = EditionBuilder().build(from: items, date: today)
            T.expect(!edition.sections.isEmpty, "the leftover items make section pages")
            T.expect(edition.sections.allSatisfy { $0.items.count <= cap },
                     "no page exceeds the cap of \(cap) "
                     + "(largest \(edition.sections.map(\.items.count).max() ?? 0))")
            // Capping must split, never discard.
            T.equal(all(edition).count, total, "every item is still in the paper")
        }

        T.suite("Lead needs a picture and a standfirst") {
            T.expect(EditionBuilder.canAnchorLead(
                item("full", at: .now, image: "https://example.com/a.jpg", summary: "A standfirst.")),
                "an item with both can lead")
            T.expect(!EditionBuilder.canAnchorLead(
                item("no image", at: .now, image: nil, summary: "A standfirst.")),
                "no picture, no lead")
            T.expect(!EditionBuilder.canAnchorLead(
                item("no words", at: .now, image: "https://example.com/a.jpg", summary: "   ")),
                "whitespace is not a standfirst")
        }

        T.suite("Nothing to build") {
            let edition = EditionBuilder().build(from: [], date: date("2026-09-09 12:00"))
            T.expect(edition.isEmpty, "an empty paper reports itself empty")
            T.equal(edition.itemCount, 0, "and holds nothing")
        }
    }

    // MARK: - Helpers

    private static func all(_ e: Edition) -> [FeedItem] {
        (e.lead.map { [$0] } ?? []) + e.secondaries + e.briefs + e.sections.flatMap(\.items)
    }

    /// A fixed calendar date, so a test cannot pass in one timezone and fail in
    /// another six hours later.
    private static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.calendar = Calendar.current
        f.timeZone = Calendar.current.timeZone
        guard let d = f.date(from: s) else {
            fatalError("test date unparseable: \(s)")
        }
        return d
    }

    private static func item(_ title: String,
                             at published: Date,
                             link: String? = nil,
                             itemId: String? = nil,
                             feedId: UUID = UUID(),
                             image: String? = "https://example.com/hero.jpg",
                             summary: String = "A standfirst long enough to count.",
                             sourceTitle: String = "fixture",
                             feedHost: String? = nil) -> FeedItem {
        let href = link ?? "https://example.com/\(title.replacingOccurrences(of: " ", with: "-"))"
        return FeedItem(
            feedId: feedId,
            itemId: itemId ?? href,
            title: title,
            link: URL(string: href)!,
            summary: summary,
            imageURL: image.flatMap(URL.init(string:)),
            publishedAt: published,
            section: "News",
            sourceTitle: sourceTitle,
            legacyItemId: nil,
            feedHost: feedHost
        )
    }
}
