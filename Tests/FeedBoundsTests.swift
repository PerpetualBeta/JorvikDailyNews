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
        T.suite("Bounds: whitespace and long names do not hide a declaration") {
            // XML's production is `'<!ENTITY' S Name S EntityDef`, and S is
            // whitespace of ANY length while a name may run to tens of
            // thousands of characters. The scan gave up after 512 bytes and
            // called it "a short hop", so 600 spaces hid the bomb completely.
            func bomb(gap: String, name: String = "big") -> Data {
                let v = String(repeating: "A", count: 4000)
                return Data(("<?xml version=\"1.0\"?>\n<!DOCTYPE rss [<!ENTITY\(gap)\(name) \"\(v)\">]>"
                    + "<rss><channel><title>&\(name);</title></channel></rss>").utf8)
            }
            for (what, gap) in [("one space", " "),
                                ("600 spaces", " " + String(repeating: " ", count: 600)),
                                ("600 tabs", " " + String(repeating: "\t", count: 600)),
                                ("600 newlines", " " + String(repeating: "\n", count: 600))] {
                T.expect(FeedFetcher.entityAmplification(in: bomb(gap: gap)) != nil, "caught: \(what)")
            }
            T.expect(FeedFetcher.entityAmplification(in: bomb(gap: " ", name: String(repeating: "n", count: 900))) != nil,
                     "caught: a 900-character entity name")
            // A declaration with no quoted value must not stall the scan.
            let external = Data("<?xml version=\"1.0\"?>\n<!DOCTYPE rss [<!ENTITY e SYSTEM \"x\">]><rss/>".utf8)
            _ = FeedFetcher.entityAmplification(in: external)
            T.expect(true, "an external declaration does not hang the scan")
        }

        T.suite("Bounds: an encoding the scan cannot read is refused") {
            // The scan looks for the ASCII bytes of <!ENTITY, so it only scans
            // documents that happen to be ASCII-compatible. EBCDIC parses
            // perfectly in libxml2 and matched nothing.
            let ibm037 = Data([0x4C, 0x6F, 0xA7, 0x94] + [UInt8](repeating: 0x40, count: 40))
            T.expect(!FeedFetcher.isReadableEncoding(ibm037), "IBM037 refused")
            for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian,
                             .isoLatin1, .windowsCP1252] {
                let d = "<?xml version=\"1.0\"?><rss><channel/></rss>".data(using: encoding) ?? Data()
                T.expect(FeedFetcher.isReadableEncoding(d), "readable: \(encoding)")
            }
            T.expect(FeedFetcher.isReadableEncoding(Data("<r/>".utf8)), "a short document")
        }

        T.suite("Bounds: a UTF-16 body is transcoded, so its size is bounded") {
            // Scanning a UTF-16 document means transcoding it, which builds a
            // whole String and then a whole Data. The comment that used to sit
            // on that said "UTF-16 feeds are rare, so the cost is paid almost
            // never" — a statement about honest feeds, where the attacker
            // picks the encoding. Measured at 181 MB maxRSS against 69 MB for
            // the same size in UTF-8, with sixteen fetches running at once.
            let small = "<?xml version=\"1.0\"?><rss><channel/></rss>"
                .data(using: .utf16LittleEndian) ?? Data()
            T.expect(FeedFetcher.scanRefusal(small) == nil, "an ordinary UTF-16 feed is scanned")

            let filler = String(repeating: "\u{4E00}", count: 3 * 1024 * 1024)
            let huge = ("<?xml version=\"1.0\"?><rss><channel><title>" + filler
                        + "</title></channel></rss>").data(using: .utf16LittleEndian) ?? Data()
            T.expect(huge.count > FeedFetcher.maxTranscodedBody, "the fixture is over the ceiling")
            T.expect(FeedFetcher.scanRefusal(huge)?.contains("UTF-16") == true,
                     "and one over it is refused, saying so")

            // The same size in UTF-8 is scanned, because nothing is transcoded.
            let utf8 = ("<?xml version=\"1.0\"?><rss><channel><title>" + filler
                        + "</title></channel></rss>").data(using: .utf8) ?? Data()
            T.expect(utf8.count > FeedFetcher.maxTranscodedBody, "and is just as big")
            T.expect(FeedFetcher.scanRefusal(utf8) == nil, "yet it is not refused")
        }

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

        T.suite("Bounds: attribute values count against the ceilings too") {
            func refused(_ xml: String) -> Bool {
                do { _ = try FeedFetcher.parse(Data(xml.utf8), from: feed); return false }
                catch { return true }
            }
            // One oversized value ends the parse on its own.
            let huge = String(repeating: "u", count: 9000)
            T.expect(refused(rss(item("<media:content url=\"\(huge)\"/>"))),
                     "a 9 KB attribute value")
            // And many merely large ones exhaust the document budget, which
            // they never touched before: textDelivered was incremented only
            // from foundCharacters and foundCDATA.
            let chunk = String(repeating: "u", count: 7000)
            let many = String(repeating: "<media:content url=\"\(chunk)\"/>", count: 1400)
            T.expect(refused(rss(item(many))), "many large values together")
            // An ordinary feed with ordinary attributes is untouched.
            T.expect(!refused(rss(item("<media:content url=\"https://e.com/a.jpg\" width=\"800\"/>"))),
                     "an ordinary enclosure passes")
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

        T.suite("Bounds: a link is a link, and a picture address too") {
            // The item cap bounds count, not bytes. `URL(string:)` accepts a
            // 65,561-character https URL and reports its host correctly, so
            // every check downstream passed it and it went into the edition
            // verbatim — which is re-encoded on the main actor at the end of
            // every refresh and decoded before any window exists.
            let padded = "https://example.com/a?q=" + String(repeating: "p", count: 60_000)
            let out = try parse(rss(item("A story", link: padded)))
            T.equal(out.items.count, 0, "an item with an absurd link is refused outright")

            // 2 KB is far past any real link. The longest in the subscribed
            // set is 312 characters.
            let long = "https://example.com/a?q=" + String(repeating: "p", count: 1800)
            T.equal(try parse(rss(item("A story", link: long))).items.count, 1,
                    "a long but plausible link still arrives")

            // Under the 8 KB attribute ceiling, so the parse succeeds and it
            // is this clamp being tested rather than that one.
            let bigPicture = "https://example.com/p.jpg?x=" + String(repeating: "z", count: 5_000)
            let withImage = "<item><title>A story</title><link>https://example.com/a</link>"
                + "<description>Words.</description>"
                + "<enclosure url=\"\(bigPicture)\" type=\"image/jpeg\"/></item>"
            let pictured = try parse(rss(withImage))
            T.equal(pictured.items.count, 1, "the item itself survives")
            T.expect(pictured.items.first?.imageURL == nil,
                     "but an absurd picture address is dropped, not truncated")
        }

        T.suite("Bounds: every ceiling counts the unit its consumer counts") {
            // A Character is a grapheme cluster with no bounded size, so every
            // clamp written as `prefix(n)` bounded nothing. Measured on this
            // toolchain: `String(title.prefix(500))` over combining marks is
            // ONE Character and 80,000 bytes.
            let accents = String(repeating: "\u{0301}", count: 40_000)
            let titled = try parse(rss(item("A" + accents)))
            let storedTitle = titled.items.first?.title ?? ""
            T.expect(storedTitle.utf16.count <= FeedFetcher.maxStoredTitle,
                     "a title is bounded in UTF-16, got \(storedTitle.utf16.count)")

            // And the link ceiling is measured on the value that is stored.
            // `URL.absoluteString` percent-encodes, so 26 Characters in became
            // 180,026 characters out, 88x over a ceiling written as 2,048.
            let comb = String(repeating: "\u{0301}", count: 30_000)
            let sneaky = try parse(rss(item("A story", link: "https://example.com/a?q=" + comb)))
            for item in sneaky.items {
                T.expect(item.link.absoluteString.utf16.count <= FeedFetcher.maxStoredURL,
                         "a stored link is inside the ceiling, got "
                         + "\(item.link.absoluteString.utf16.count)")
            }
        }

        T.suite("Bounds: UTF-16 that will not decode is refused, not waved through") {
            // Two trailing bytes of lone surrogate made Foundation refuse the
            // string, `utf8Bytes` fall back to the raw UTF-16, and the ASCII
            // `<!ENTITY` scan match nothing — while libxml2 decoded the body
            // perfectly well and paid the full amplification. Not enough to
            // trouble the parser, enough to blind the guard.
            let value = String(repeating: "A", count: 40_000)
            let refs = String(repeating: "&big;", count: 200)
            let doc = "<?xml version=\"1.0\"?>\n<!DOCTYPE rss [<!ENTITY big \"" + value + "\">]>"
                + "<rss><channel><title>" + refs + "</title></channel></rss>"
            var utf16 = Data([0xFF, 0xFE])
            utf16.append(contentsOf: Array(doc.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            T.expect(FeedFetcher.entityAmplification(in: utf16) != nil,
                     "the clean UTF-16 bomb is caught")

            var poisoned = utf16
            poisoned.append(contentsOf: [0x00, 0xD8])
            T.expect(FeedFetcher.entityAmplification(in: poisoned) == nil,
                     "the entity scan alone is blind to the poisoned one — this is the bypass")
            T.expect(FeedFetcher.scanRefusal(poisoned)?.contains("will not decode") == true,
                     "so scanRefusal has to be the thing that catches it")
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

        T.suite("Feeds: a two-digit year is the year RFC 822 means") {
            // `DateFormatter`'s `yyyy` accepts two digits and answers year 25
            // rather than declining, so keithclark.co.uk's perfectly legal
            // `Wed, 01 Oct 25 23:31:20 +0000` dated its items to the first
            // century. `EditionBuilder` sorts date-descending, so every
            // article from that feed lost every comparison and never reached a
            // page — silently, with the parse reporting success.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            func year(of xml: String) throws -> Int? {
                guard let d = try parse(xml).items.first?.publishedAt else { return nil }
                return cal.component(.year, from: d)
            }
            func dated(_ pubDate: String) -> String {
                rss("<item><title>T</title><link>https://example.com/a</link>"
                    + "<pubDate>\(pubDate)</pubDate></item>")
            }
            T.equal(try year(of: dated("Wed, 01 Oct 25 23:31:20 +0000")), 2025,
                    "the measured case reads as 2025, not 25")
            T.equal(try year(of: dated("01 Oct 25 23:31:20 +0000")), 2025,
                    "and so does the form with no day name")
            T.equal(try year(of: dated("Wed, 01 Oct 99 12:00:00 GMT")), 1999,
                    "the pivot puts 99 in the 1900s")
            T.equal(try year(of: dated("Wed, 01 Oct 2025 23:31:20 +0000")), 2025,
                    "a four-digit year is untouched")
            T.equal(try year(of: dated("2025-10-01T23:31:20Z")), 2025,
                    "and so is RFC 3339")
            // A genuinely old archive item must survive. The plausibility
            // floor is 1990, comfortably below the oldest real one measured
            // (True Tiger Recordings, 2005-12-09).
            T.equal(try year(of: dated("Fri, 09 Dec 2005 00:00:00 +0000")), 2005,
                    "an old archive item keeps its own date")
        }

        T.suite("Feeds: reviewing a feed opens the site, never the XML") {
            func feed(_ urlString: String, site: String? = nil) -> Feed {
                Feed(url: URL(string: urlString)!, section: "News", title: nil,
                     siteURL: site.flatMap { URL(string: $0) })
            }
            let apple = feed("https://images.apple.com/main/rss/hotnews/hotnews.rss")
            T.equal(apple.reviewURL?.absoluteString, "https://images.apple.com/",
                    "with no channel link it is the host, not the feed file")
            let withSite = feed("https://images.apple.com/main/rss/hotnews/hotnews.rss",
                                site: "https://www.apple.com/newsroom/")
            T.equal(withSite.reviewURL?.absoluteString, "https://www.apple.com/newsroom/",
                    "the channel link wins when the feed published one")
            // The channel link is a string the feed chooses, so it goes
            // through the same gate as anything else the app would open.
            let hostile = feed("https://example.com/f.xml", site: "file:///etc/passwd")
            T.equal(hostile.reviewURL?.absoluteString, "https://example.com/",
                    "a channel link that is not a web address is ignored")
            let notWeb = Feed(url: URL(string: "file:///tmp/f.xml")!, section: "News")
            T.expect(notWeb.reviewURL == nil,
                     "and a feed with no web address at all offers nothing")
        }

        T.suite("Feeds: one that has quietly stopped working is noticed") {
            let now = Date()
            let day = Feed.silentFailureThreshold
            func feed(success: Date?, failure: Date?) -> Feed {
                Feed(url: URL(string: "https://example.com/f.xml")!, section: "News",
                     title: nil, lastSuccessfulFetchAt: success, lastFailedFetchAt: failure)
            }
            T.expect(!feed(success: nil, failure: nil).isSilentlyFailing(asOf: now),
                     "a feed never tried is not failing")
            T.expect(!feed(success: now, failure: nil).isSilentlyFailing(asOf: now),
                     "nor is one that has only ever worked")
            T.expect(!feed(success: now, failure: now.addingTimeInterval(-day * 3))
                        .isSilentlyFailing(asOf: now),
                     "nor one that failed long ago and works now")
            T.expect(!feed(success: now.addingTimeInterval(-60), failure: now)
                        .isSilentlyFailing(asOf: now),
                     "a single fresh failure is not an announcement")
            T.expect(feed(success: now.addingTimeInterval(-day * 2), failure: now)
                        .isSilentlyFailing(asOf: now),
                     "but two days of failure is")
            T.expect(feed(success: nil, failure: now.addingTimeInterval(-day * 2))
                        .isSilentlyFailing(asOf: now),
                     "and so is one that has never once succeeded")
            // Exactly at the threshold counts, so the boundary is stated.
            T.expect(feed(success: now.addingTimeInterval(-day), failure: now)
                        .isSilentlyFailing(asOf: now),
                     "the boundary itself counts")
        }

        T.suite("Feeds: the notice agrees with how many there are") {
            func named(_ title: String) -> Feed {
                // The host is a slug of the title: a real title has spaces in
                // it, and `URL(string:)` answers nil to those.
                let host = title.lowercased().replacingOccurrences(of: " ", with: "-")
                return Feed(url: URL(string: "https://\(host).example/f.xml")!,
                            section: "News", title: title)
            }
            let one = [named("Don Melton")]
            let two = [named("Don Melton"), named("Adrian Holovaty")]
            let three = two + [named("Newton Poetry")]
            let nine = (0..<9).map { named("Feed \($0)") }

            T.equal(one.silentFailureSentence,
                    "Don Melton has not been reachable for over a day.", "one is named")
            T.equal(one.silentFailureAction, "Review it", "and the action is singular")

            T.expect(two.silentFailureSentence.hasPrefix("Don Melton, Adrian Holovaty have"),
                     "two are both named, with a plural verb")
            T.equal(two.silentFailureAction, "Review them", "and the action is plural")
            T.expect(three.silentFailureSentence.contains("Newton Poetry have not been"),
                     "three are still named")

            T.equal(nine.silentFailureSentence,
                    "9 feeds have not been reachable for over a day.",
                    "beyond three it is a count")
            T.equal(nine.silentFailureAction, "Review them", "still plural")

            // A feed with no title falls back to its host, never to nothing.
            let hostOnly = [Feed(url: URL(string: "https://donmelton.com/rss.xml")!,
                                 section: "Tech", title: nil)]
            T.expect(hostOnly.silentFailureSentence.hasPrefix("donmelton.com has"),
                     "an untitled feed is named by its host")
            T.equal([Feed]().silentFailureSentence, "", "and none says nothing at all")

            // The dormancy wording shares the counting and differs in the
            // claim, so both halves are pinned.
            T.equal(one.dormantSentence,
                    "Don Melton has published nothing for over a year.",
                    "one dormant feed is named")
            T.equal(nine.dormantSentence,
                    "9 feeds have published nothing for over a year.",
                    "beyond three it is a count here too")
            T.equal([Feed]().dormantSentence, "", "and none says nothing at all")
        }

        T.suite("Feeds: one that answers and publishes nothing is noticed") {
            let now = Date()
            let year = Feed.dormancyThreshold
            func feed(newest: Date?, paused: Bool = false,
                      success: Date? = nil, failure: Date? = nil,
                      announced: Date? = nil) -> Feed {
                Feed(url: URL(string: "https://example.com/f.xml")!, section: "News",
                     title: nil, isPaused: paused,
                     lastSuccessfulFetchAt: success ?? now, lastFailedFetchAt: failure,
                     newestItemAt: newest, dormancyAnnouncedAt: announced)
            }
            T.expect(!feed(newest: nil).isDormant(asOf: now),
                     "a feed that has dated nothing is never called dormant")
            T.expect(!feed(newest: now).isDormant(asOf: now),
                     "nor is one that published today")
            T.expect(!feed(newest: now.addingTimeInterval(-year / 2)).isDormant(asOf: now),
                     "nor one quiet for six months")
            T.expect(feed(newest: now.addingTimeInterval(-year)).isDormant(asOf: now),
                     "the boundary itself counts")
            T.expect(feed(newest: now.addingTimeInterval(-year * 10)).isDormant(asOf: now),
                     "and ten years certainly does")
            T.expect(!feed(newest: now.addingTimeInterval(-year * 10), paused: true)
                        .isDormant(asOf: now),
                     "a paused feed is not dormant; not fetching it is the point")

            // **One feed, one fault.** A feed that is both unreachable and
            // long-dormant would otherwise appear under the dateline twice,
            // in two sentences that contradict each other about whether it
            // works.
            let broken = feed(newest: now.addingTimeInterval(-year * 10),
                              success: now.addingTimeInterval(-Feed.silentFailureThreshold * 3),
                              failure: now)
            T.expect(broken.isSilentlyFailing(asOf: now), "it is unreachable")
            T.expect(!broken.isDormant(asOf: now), "so it is not also reported as dormant")

            // Said once.
            let quiet = feed(newest: now.addingTimeInterval(-year * 2))
            T.expect(quiet.isUnannouncedDormant(asOf: now), "a new one is worth saying")
            T.expect(!feed(newest: now.addingTimeInterval(-year * 2), announced: now)
                        .isUnannouncedDormant(asOf: now),
                     "and having said it, the paper does not say it again")
        }

        T.suite("Feeds: a dormant feed that wakes up may be reported again") {
            let now = Date()
            let year = Feed.dormancyThreshold
            var feed = Feed(url: URL(string: "https://example.com/f.xml")!,
                            section: "News", title: "Example",
                            lastSuccessfulFetchAt: now,
                            newestItemAt: now.addingTimeInterval(-year * 2),
                            dormancyAnnouncedAt: now.addingTimeInterval(-year))
            T.expect(!feed.isUnannouncedDormant(asOf: now), "already mentioned, so not again")

            feed.recordSuccess(newestItemAt: now, at: now)
            T.expect(!feed.isDormant(asOf: now), "publishing again ends dormancy")
            T.expect(feed.dormancyAnnouncedAt == nil,
                     "and the mention is cleared, so a second silence is reported like the first")

            // A fetch that carries no dates must not erase what is known.
            feed.recordSuccess(newestItemAt: nil, at: now)
            T.equal(feed.newestItemAt, now, "a dateless fetch leaves the recorded date alone")

            // And a fetch that succeeds clears a standing failure, which is
            // what the dormancy check depends on to tell the two apart.
            feed.lastFailedFetchAt = now
            feed.recordSuccess(newestItemAt: nil, at: now)
            T.expect(feed.lastFailedFetchAt == nil, "a success clears the failure mark")
        }
    }
}
