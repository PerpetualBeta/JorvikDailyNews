import Foundation

enum FeedFetchError: Error, LocalizedError {
    case invalidResponse(Int)
    case parseFailure
    case emptyFeed
    /// The response is well-formed XML but it is not a feed. Distinct from
    /// `parseFailure` because it fails in the opposite way: nothing errors.
    case notAFeed(root: String)
    /// A parse failure that can say where and why.
    case parseFailureDetail(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let code): "Server returned \(code)"
        case .parseFailure: "Could not parse feed"
        case .emptyFeed: "Feed contained no items"
        case .notAFeed(let root): "Served a <\(root)> document, not a feed"
        case .parseFailureDetail(let detail): "Could not parse feed — \(detail)"
        }
    }
}

struct FetchedFeed {
    let title: String
    let items: [FeedItem]
}

final class FeedFetcher: Sendable {
    func fetch(_ feed: Feed) async throws -> FetchedFeed {
        var request = URLRequest(url: feed.url)
        request.setValue(
            "JorvikDailyNews/0.1 (+https://jorviksoftware.cc)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await BoundedFetch.data(for: request, on: .shared, limit: BoundedFetch.markupLimit)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedFetchError.invalidResponse(http.statusCode)
        }

        return try Self.parse(data, from: feed)
    }

    /// Turn bytes into a feed, with no network involved.
    ///
    /// Split out of `fetch` so it can be exercised against saved fixtures.
    /// Four faults lived in this code from the day it was written — items
    /// above a parse error discarded, an HTML page counting as a healthy
    /// feed, RSS 1.0 silently dropped, and two root checks disagreeing — and
    /// every one is a pure function of these bytes. They went unnoticed
    /// because nothing could call this without a network and a user
    /// interface. See `Tests/FeedFetcherTests.swift`.
    static func parse(_ data: Data, from feed: Feed) throws -> FetchedFeed {
        let parser = RSSAtomParser(data: data, feed: feed)
        guard let result = parser.parse() else {
            // Two different faults, and lumping them together hid one of them
            // for as long as this app has existed. "Could not parse" is a
            // malformed feed. "Served a <html> document" is a feed that has
            // been retired and replaced with a web page, which is a thing to
            // go and fix rather than wait out.
            if let wrong = parser.wrongRoot { throw FeedFetchError.notAFeed(root: wrong) }
            if let detail = parser.failureDetail {
                throw FeedFetchError.parseFailureDetail(detail)
            }
            throw FeedFetchError.parseFailure
        }
        return result
    }
}

final class RSSAtomParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private let feed: Feed

    private var channelTitle = ""
    private var items: [FeedItem] = []

    private enum Flavour { case unknown, rss, atom }
    private var flavour: Flavour = .unknown

    private var path: [String] = []
    /// The document's outermost element, so a fetch can tell a feed from a web
    /// page. An HTML page is usually well-formed enough to satisfy `XMLParser`,
    /// which then reports a clean parse of a document containing no items.
    private var rootElement: String?
    private var buffer = ""

    private struct ItemBuilder {
        var title = ""
        var link = ""
        var guid = ""
        var description = ""
        var contentEncoded = ""
        var pubDate = ""
        var updated = ""
        var published = ""
        // All image candidates with declared widths (0 = unknown). Some feeds
        // (e.g. The Guardian) ship multiple `<media:content>` elements at
        // different sizes; we pick the widest so we don't render a 140-pixel
        // thumbnail at 280-pixel height.
        var imageCandidates: [(url: String, width: Int)] = []
    }
    private var current: ItemBuilder?

    init(data: Data, feed: Feed) {
        self.parser = XMLParser(data: data)
        self.feed = feed
        super.init()
        self.parser.delegate = self
    }

    /// Keeps what parsed, rather than discarding a feed because it breaks
    /// somewhere near the bottom.
    ///
    /// `XMLParser` reports items to the delegate as it goes, so by the time it
    /// hits bad markup `items` already holds everything above the fault.
    /// Returning nil threw all of that away. Measured on
    /// `nickschaden.com/feed/` on 2026-09-09: **nine items parse cleanly** and
    /// the parser then dies at line 726 on an unterminated `<![CDATA[`, so the
    /// reader was losing nine perfectly good articles to a defect 726 lines
    /// past them. That feed reads as simply dead in the log, which is why it
    /// went unnoticed.
    ///
    /// An item is only appended once its closing tag is seen, so a half-read
    /// item at the point of failure was never added and cannot leak through.
    /// Nothing is returned when nothing parsed, so a server handing back an
    /// HTML page still fails as it should.
    /// Why `XMLParser` gave up, if it did. Without this a parse failure could
    /// only ever be reported as "could not parse feed", which names no line, no
    /// column and no reason, and is therefore unactionable for the one person
    /// who could fix it — whoever publishes the feed.
    private var parseError: String?

    /// An element name without its namespace prefix.
    ///
    /// `XMLParser` runs without namespace processing here, so RSS 1.0 reports
    /// its root as `rdf:RDF` rather than `RDF`. Comparing qualified names
    /// against bare ones rejected a working feed, so both the root check and
    /// the flavour detection go through this.
    static func localName(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map(String.init) ?? qualified
    }

    /// The outermost elements a feed can legitimately have. RSS 2.0 is `rss`,
    /// Atom is `feed`, and RSS 1.0 is an RDF document. Anything else is not a
    /// feed however cleanly it parses.
    private static let feedRoots: Set<String> = ["rss", "feed", "rdf"]

    /// Whether an element name is a root a feed can legitimately have.
    ///
    /// One predicate, because the first version of this asked the same question
    /// in two places and got two answers: `parse()` compared the qualified name
    /// `rdf:rdf` against the bare set and rejected it, while `wrongRoot`
    /// compared the local name and accepted it. The feed was then reported as
    /// "could not parse" with no detail, because the detailed paths had both
    /// concluded there was nothing wrong. A set plus two call sites is a
    /// standing invitation to that; a function is not.
    static func isFeedRoot(_ elementName: String) -> Bool {
        feedRoots.contains(localName(elementName))
    }

    /// What went wrong and where, for the log. Nil when nothing went wrong.
    var failureDetail: String? {
        guard let parseError else { return nil }
        return "root <\(rootElement ?? "none")>, \(items.count) item(s) built, \(parseError)"
    }

    /// The root element when it is not one a feed can have, so the caller can
    /// report "served a web page" rather than the misleading "could not parse".
    /// Nil when the document is feed-shaped or never got as far as an element.
    var wrongRoot: String? {
        guard let rootElement else { return nil }
        guard !Self.isFeedRoot(rootElement) else { return nil }
        return rootElement
    }

    func parse() -> FetchedFeed? {
        guard parser.parse() else {
            guard !items.isEmpty else { return nil }
            jdnLog("fetch: \(feed.url.host ?? "?") is malformed at line "
                   + "\(parser.lineNumber) — keeping the \(items.count) item(s) "
                   + "that parsed before it")
            return FetchedFeed(title: channelTitle, items: items)
        }
        // A clean parse is not the same as a feed.
        //
        // FeedBurner serves a plain web page for retired feeds, and an HTML
        // page is usually well-formed enough that `XMLParser` accepts it. The
        // fetch was then recorded as a success containing no items, so a feed
        // that had quietly died looked exactly like a blog nobody had updated,
        // and it never appeared in the failure count. Measured 2026-09-09 on
        // `feeds.feedburner.com/philwhelansblog`: PARSED, root <html>, 0 items.
        guard let rootElement, Self.isFeedRoot(rootElement) else {
            return nil
        }
        return FetchedFeed(title: channelTitle, items: items)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = "line \(parser.lineNumber) col \(parser.columnNumber): "
                   + error.localizedDescription
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if rootElement == nil { rootElement = name }
        path.append(name)
        buffer = ""

        if flavour == .unknown {
            // RSS 1.0 was never recognised, and the consequence was invisible.
            //
            // Its root is `rdf:RDF`, which matched neither test, so `flavour`
            // stayed `.unknown`. `<link>` is only read for the RSS flavour, so
            // every item came out with no link, and `buildItem` rejects an item
            // without an `http` link. The parse succeeded, ten items were
            // built, and all ten were discarded. Nothing was logged, because
            // `emptyFeed` is declared and never thrown, so the fetch was
            // recorded as a healthy feed that happened to be empty.
            //
            // Measured on `nedbatchelder.com/blog/rss.xml` on 2026-09-09: 69 KB,
            // parses clean, 10 items, 0 kept. RSS 1.0 carries its link the
            // same way RSS 2.0 does, as element text, so it takes the RSS path.
            switch Self.localName(name) {
            case "rss", "rdf": flavour = .rss
            case "feed": flavour = .atom
            default: break
            }
        }

        switch name {
        case "item", "entry":
            current = ItemBuilder()
        case "link":
            // Atom: <link href="..."/> with optional rel
            if flavour == .atom {
                let href = attributeDict["href"] ?? ""
                let rel = attributeDict["rel"] ?? "alternate"
                if current != nil {
                    if rel == "alternate" && current!.link.isEmpty {
                        current!.link = href
                    }
                    if rel == "enclosure", let type = attributeDict["type"], type.hasPrefix("image/") {
                        let width = Int(attributeDict["length"] ?? "") ?? 0
                        current!.imageCandidates.append((href, width))
                    }
                }
            }
        case "enclosure":
            // RSS: <enclosure url="..." type="image/..."/>
            if let type = attributeDict["type"], type.hasPrefix("image/"),
               let url = attributeDict["url"] {
                current?.imageCandidates.append((url, 0))
            }
        case "media:thumbnail", "media:content":
            if let url = attributeDict["url"] {
                let width = Int(attributeDict["width"] ?? "") ?? 0
                current?.imageCandidates.append((url, width))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            buffer.append(s)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer {
            if !path.isEmpty { path.removeLast() }
            buffer = ""
        }

        let name = elementName.lowercased()
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        // Channel / feed title (outside an item/entry)
        if current == nil {
            let inChannel = path.contains("channel") || path.contains("feed")
            if inChannel && name == "title" && channelTitle.isEmpty {
                channelTitle = text
            }
        }

        guard current != nil else {
            if name == "channel" || name == "feed" { /* nothing */ }
            return
        }

        switch name {
        case "title":
            if current!.title.isEmpty { current!.title = text }
        case "link":
            if flavour == .rss && current!.link.isEmpty { current!.link = text }
        case "guid", "id":
            if current!.guid.isEmpty { current!.guid = text }
        case "description", "summary":
            if current!.description.isEmpty { current!.description = text }
        case "content:encoded", "content":
            if current!.contentEncoded.isEmpty { current!.contentEncoded = text }
        case "pubdate":
            current!.pubDate = text
        case "updated":
            current!.updated = text
        case "published":
            current!.published = text
        case "item", "entry":
            if let built = finalise(current!) {
                items.append(built)
            }
            current = nil
        default:
            break
        }
    }

    // MARK: - Finalisation

    private func finalise(_ b: ItemBuilder) -> FeedItem? {
        let title = Standfirst.decodeEntities(b.title).trimmed
        guard !title.isEmpty else { return nil }
        guard let originalLink = URL(string: b.link.trimmingCharacters(in: .whitespacesAndNewlines)),
              originalLink.scheme?.hasPrefix("http") == true else { return nil }

        let bodyHTML = !b.contentEncoded.isEmpty ? b.contentEncoded : b.description
        // Link aggregators (HN, Reddit, Lobste.rs, etc.) give you the
        // discussion URL where an article URL would be. For those, look in
        // the body HTML for the first external href and use that instead —
        // the target matters more than the meta-commentary.
        let link = resolveTargetURL(originalLink, in: bodyHTML)
        let summary = cleanSummary(Standfirst.extract(from: bodyHTML))
        let imageURL = pickBestImage(candidates: b.imageCandidates, bodyHTML: bodyHTML)

        // Undated items rank LAST on the front page rather than masquerading
        // as "newest" (Date()) which would dominate anything correctly dated.
        let date = parseDate(b.published, b.updated, b.pubDate) ?? Date.distantPast
        let itemId = b.guid.isEmpty ? link.absoluteString : b.guid
        let sourceTitle = feed.title?.isEmpty == false ? feed.title! : channelTitle

        return FeedItem(
            feedId: feed.id,
            itemId: itemId,
            title: title,
            link: link,
            summary: summary,
            imageURL: imageURL,
            publishedAt: date,
            section: feed.section,
            sourceTitle: sourceTitle
        )
    }

    private func parseDate(_ candidates: String...) -> Date? {
        for raw in candidates where !raw.isEmpty {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // ISO8601DateFormatter handles RFC3339 including the `.SSS`
            // fractional-seconds variant that many Atom feeds ship — a form
            // DateFormatter with a fixed pattern rejects.
            if let d = Self.iso8601FS.date(from: s) { return d }
            if let d = Self.iso8601.date(from: s) { return d }
            // RFC822 variants: named timezone vs. numeric offset, with and
            // without seconds, with and without the leading day-name.
            for f in Self.fallbackFormatters {
                if let d = f.date(from: s) { return d }
            }
        }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let iso8601FS: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fallbackFormatters: [DateFormatter] = {
        let patterns = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd"
        ]
        return patterns.map { p in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = p
            return f
        }
    }()

    /// Aggregator proxies (hnrss.org) and some podcast feeds append metadata
    /// boilerplate — "Article URL: … Comments URL: … Points: 3 # Comments: 0" —
    /// where a standfirst belongs. Cut it off wherever it starts.
    ///
    /// It used to be matched as a PREFIX and the whole summary discarded, which
    /// only worked when the boilerplate came first. A Hacker News item whose
    /// submitter wrote something before it kept the lot: "is it like ai first
    /// os? Comments URL: https://news.ycombinator.com/item?id=49585527 Points: 2
    /// # Comments: 0". Cutting rather than discarding keeps the submitter's
    /// words and drops the machinery, and still yields "" when the boilerplate
    /// is the entire summary.
    ///
    /// Only the two URL markers are matched, never `Points:` on its own. In
    /// hnrss's template a URL marker always comes first, so cutting there takes
    /// the whole tail — and `Points:` is a phrase that turns up in real prose,
    /// where it would truncate a genuine standfirst mid-sentence.
    private func cleanSummary(_ s: String) -> String {
        let markers = ["article url:", "comments url:", "submitted by", "link: ", "url: "]
        let lower = s.lowercased()
        let cut = markers.compactMap { lower.range(of: $0)?.lowerBound }.min()
        guard let cut else { return s }
        return String(s[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Aggregator target resolution

    private static let aggregatorHosts: Set<String> = [
        "news.ycombinator.com",
        "hn.algolia.com",
        "hnrss.org",
        "lobste.rs",
        "reddit.com",
        "www.reddit.com",
        "old.reddit.com",
        "slashdot.org"
    ]

    private static func isAggregatorHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if aggregatorHosts.contains(host) { return true }
        if host.hasSuffix(".reddit.com") { return true }
        return false
    }

    private func resolveTargetURL(_ link: URL, in html: String) -> URL {
        guard Self.isAggregatorHost(link.host) else { return link }
        guard let target = firstExternalURL(in: html) else { return link }
        return target
    }

    /// First http(s) URL inside an `href` attribute whose host is not a
    /// known aggregator. Skips self-referential and discussion links.
    private func firstExternalURL(in html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "href=[\"']([^\"']+)[\"']", options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: html) else { continue }
            let href = String(html[r])
            guard let url = URL(string: href),
                  let scheme = url.scheme, scheme == "http" || scheme == "https",
                  url.host != nil else { continue }
            if Self.isAggregatorHost(url.host) { continue }
            return url
        }
        return nil
    }

    /// Pick the best image candidate from the feed, preferring the widest
    /// declared size. If the widest is known to be < 400px (thumbnail-only
    /// feeds like some Guardian category feeds), skip it and fall through to
    /// body HTML images or downstream og:image enrichment.
    private func pickBestImage(candidates: [(url: String, width: Int)], bodyHTML: String) -> URL? {
        let widest = candidates.max(by: { $0.width < $1.width })
        if let best = widest, best.width == 0 || best.width >= 400 {
            if let url = URL(string: best.url) { return url }
        }
        return firstImageURL(in: bodyHTML)
    }

    private func firstImageURL(in html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']", options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return URL(string: String(html[r]))
    }

}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
