import Foundation

enum FeedFetchError: Error, LocalizedError {
    case invalidResponse(Int)
    case parseFailure
    case emptyFeed

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let code): "Server returned \(code)"
        case .parseFailure: "Could not parse feed"
        case .emptyFeed: "Feed contained no items"
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

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedFetchError.invalidResponse(http.statusCode)
        }

        let parser = RSSAtomParser(data: data, feed: feed)
        guard let result = parser.parse() else { throw FeedFetchError.parseFailure }
        return result
    }
}

private final class RSSAtomParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private let feed: Feed

    private var channelTitle = ""
    private var items: [FeedItem] = []

    private enum Flavour { case unknown, rss, atom }
    private var flavour: Flavour = .unknown

    private var path: [String] = []
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

    func parse() -> FetchedFeed? {
        guard parser.parse() else { return nil }
        return FetchedFeed(title: channelTitle, items: items)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        path.append(name)
        buffer = ""

        if flavour == .unknown {
            if name == "rss" { flavour = .rss }
            else if name == "feed" { flavour = .atom }
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
        let title = decodeEntities(b.title).trimmed
        guard !title.isEmpty else { return nil }
        guard let originalLink = URL(string: b.link.trimmingCharacters(in: .whitespacesAndNewlines)),
              originalLink.scheme?.hasPrefix("http") == true else { return nil }

        let bodyHTML = !b.contentEncoded.isEmpty ? b.contentEncoded : b.description
        // Link aggregators (HN, Reddit, Lobste.rs, etc.) give you the
        // discussion URL where an article URL would be. For those, look in
        // the body HTML for the first external href and use that instead —
        // the target matters more than the meta-commentary.
        let link = resolveTargetURL(originalLink, in: bodyHTML)
        let summary = cleanSummary(htmlToPlain(bodyHTML))
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

    /// Aggregator proxies (hnrss.org) and some podcast feeds inject metadata
    /// boilerplate like "Article URL: ... Comments URL: ... Points: 3" in
    /// place of an actual standfirst. Suppress that entirely — it's noise.
    private func cleanSummary(_ s: String) -> String {
        let lower = s.lowercased()
        let boilerplatePrefixes = [
            "article url:",
            "comments url:",
            "submitted by",
            "link: ",
            "url: "
        ]
        if boilerplatePrefixes.contains(where: { lower.hasPrefix($0) }) {
            return ""
        }
        return s
    }

    private func htmlToPlain(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func decodeEntities(_ s: String) -> String {
        var out = s
        let pairs: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&ndash;", "\u{2013}"), ("&mdash;", "\u{2014}"),
            ("&hellip;", "\u{2026}"), ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&#8217;", "\u{2019}")
        ]
        for (from, to) in pairs { out = out.replacingOccurrences(of: from, with: to) }
        return out
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
