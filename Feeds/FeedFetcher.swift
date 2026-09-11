import CryptoKit
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
    // MARK: - Entity amplification

    /// An internal entity big enough to be a weapon, described, or nil.
    ///
    /// This has to happen BEFORE parsing, and finding that out cost a wrong
    /// answer. The obvious defence is to cap how much text the parser hands
    /// back, and it does not work: measured against a 1,548,742-byte document
    /// declaring a 1 MB entity referenced 100,000 times, an 8 MB ceiling on
    /// delivered text made **no difference at all** — 61.39 seconds either
    /// way, with 19 MB of resident memory. The cost is inside libxml2, which
    /// rescans the entity value at every reference, and it is paid before
    /// enough callbacks arrive to trip any counter of mine. Nothing downstream
    /// of the parser can help.
    ///
    /// Refusing internal entities outright would work and is too blunt.
    /// XML predefines only five, so a feed wanting `&nbsp;` must declare it,
    /// and real feeds do:
    ///
    ///     <!DOCTYPE rss [ <!ENTITY nbsp "&#160;"> ]>
    ///
    /// The weapon is the entity's SIZE, not its existence. `&nbsp;` is six
    /// bytes. So a declaration is allowed and a large one is not, which keeps
    /// every legitimate use and removes the amplification: with values bounded
    /// at 256 bytes, even a 32 MB document packed edge to edge with
    /// references expands to under two gigabytes of logical text rather than
    /// the 98 GB above.
    /// Ceilings on what one item may carry into the edition.
    ///
    /// Nothing truncated these before. `FeedItem.title` and `.summary` are
    /// plain `String`s that go into the edition JSON, are rewritten on every
    /// refresh, are laid out by the masonry and are measured by the standfirst
    /// fitter. A headline is a headline; `leadTargetWords` is 200, so 4,000
    /// characters of summary is already several times what any card can show.
    static let maxStoredTitle = 500
    static let maxStoredSummary = 4000
    /// Items taken from one feed.
    static let maxItemsPerFeed = 500

    /// An item's identity, scoped to the feed that offered it.
    ///
    /// Hashed rather than concatenated so the result is a fixed length: this
    /// string is a dictionary key in `read.json` and `classifier.json`, both
    /// of which are rewritten whole, and a guid can be as long as a feed
    /// likes.
    static func namespacedID(_ offered: String, in feedId: UUID) -> String {
        let digest = SHA256.hash(data: Data((feedId.uuidString + "\u{1F}" + offered).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static let maxEntityValue = 256
    static let maxEntityDeclarations = 64

    /// Scanned over bytes, and deliberately never reads a whole entity value.
    ///
    /// The first version of this decoded a 64 KB prefix and matched
    /// `<!ENTITY name "value">` with a regex. It made no difference — still
    /// 61 seconds — and the reason is worth keeping: the bomb's value is
    /// **1 MB**, so its closing quote lies far outside a 64 KB window and the
    /// pattern never matched. The guard was blind to precisely the shape it
    /// exists to catch, and only measuring said so.
    ///
    /// So a value that cannot be closed within the limit IS the answer. This
    /// finds each declaration's opening quote and looks ahead at most
    /// `maxEntityValue + 1` bytes for its partner. Not finding one means the
    /// value is longer than that, which is all it needs to know, and the
    /// scan therefore costs the same on a bomb as on a real feed.
    /// The body as UTF-8 bytes, transcoding when it is not.
    ///
    /// **A UTF-16 feed spelled `<!ENTITY` as `3C 00 21 00 …` and matched
    /// nothing**, while `XMLParser(data:)` decoded it perfectly well and parsed
    /// the bomb. A byte scan for an ASCII marker is only a scan of documents
    /// that happen to be ASCII-compatible, and nothing had said so.
    ///
    /// Only the scan is transcoded. `XMLParser` still receives the original
    /// bytes and does its own encoding detection, so nothing about parsing
    /// changes. UTF-16 feeds are rare, so the cost is paid almost never.
    private static func utf8Bytes(of data: Data) -> Data {
        guard data.count >= 2 else { return data }
        let b = [UInt8](data.prefix(2))
        let encoding: String.Encoding?
        switch (b[0], b[1]) {
        case (0xFF, 0xFE): encoding = .utf16LittleEndian
        case (0xFE, 0xFF): encoding = .utf16BigEndian
        default:
            // No BOM. A UTF-16 document without one still starts with a NUL in
            // one of the first two bytes of `<?xml` or `<rss`, which UTF-8
            // never does.
            if b[0] == 0x00 { encoding = .utf16BigEndian }
            else if b[1] == 0x00 { encoding = .utf16LittleEndian }
            else { return data }
        }
        guard let encoding,
              let text = String(data: data, encoding: encoding),
              let utf8 = text.data(using: .utf8)
        else {
            // Undecodable as the encoding its own bytes advertise. Returning the
            // original means the scan sees something it cannot match, so the
            // safe answer is to let the caller refuse the feed instead.
            return data
        }
        return utf8
    }

    private static func entityAmplification(in data: Data) -> String? {
        let marker = Array("<!ENTITY".utf8)
        // **The whole document, not a prefix.** This used to scan the first
        // 256 KB, justified by "an internal DTD can only be in the prolog".
        // That is true and it is not a bound: XML's prolog is
        // `XMLDecl Misc* doctypedecl Misc*`, and `Misc` is comments and
        // processing instructions of ANY length. A 300 KB comment before the
        // `<!DOCTYPE` pushed the declaration past the window, the guard
        // returned nil, and libxml2 then rescanned the entity value at every
        // reference. The text ceilings cannot catch it, for the reason this
        // file already explains: with a 1 MB value and 100,000 references only
        // 18 bytes reach `foundCharacters`.
        //
        // The scan is linear with a bounded look-ahead, so the window bought
        // nothing but the hole.
        let bytes = [UInt8](utf8Bytes(of: data))
        guard bytes.count > marker.count else { return nil }

        var found = 0
        var i = 0
        while i <= bytes.count - marker.count {
            guard bytes[i] == marker[0],
                  Array(bytes[i..<(i + marker.count)]).elementsEqual(marker)
            else { i += 1; continue }
            found += 1
            if found > maxEntityDeclarations {
                return "more than \(maxEntityDeclarations) internal entities"
            }
            // The opening quote of the value, if there is one nearby. A name
            // and whitespace, so this is a short hop.
            var j = i + marker.count
            let nameLimit = min(bytes.count, j + 512)
            while j < nameLimit, bytes[j] != 0x22, bytes[j] != 0x27 { j += 1 }
            guard j < nameLimit else { i += marker.count; continue }
            let quote = bytes[j]
            // Its partner, within the limit or not at all.
            let valueStart = j + 1
            let searchEnd = min(bytes.count, valueStart + maxEntityValue + 1)
            var k = valueStart
            while k < searchEnd, bytes[k] != quote { k += 1 }
            if k >= searchEnd {
                return "an internal entity of at least \(k - valueStart) bytes, "
                     + "over the \(maxEntityValue) allowed"
            }
            i = k + 1
        }
        return nil
    }

    /// A publication date, never in the future.
    ///
    /// Nothing clamped this, and the edition sorts strictly newest-first and
    /// then keeps the FIRST item met per link. So a feed dating its items at
    /// 23:59 today sorted above everything genuine and won every link
    /// collision — and the genuine copy was dropped with no error and no log
    /// line. Copy a major outlet's `<link>`s, put your own headlines and
    /// standfirsts on them, and the card carries the victim's name, because
    /// `sourceTitle` prefers the channel title. Clicking it opens the real
    /// article, which is what makes it credible.
    ///
    /// Clamping does not make the dedupe fair on its own — see the tie-break in
    /// `EditionBuilder.dedupeByLink` — but it removes the half that let an
    /// attacker sort to the top of every section for free.
    ///
    /// A small allowance for clock skew, because a publisher a minute fast is
    /// ordinary and should not have its items quietly restamped.
    static func clamped(_ date: Date, now: Date = Date()) -> Date {
        let allowance: TimeInterval = 5 * 60
        return date > now.addingTimeInterval(allowance) ? now : date
    }

    static func parse(_ data: Data, from feed: Feed) throws -> FetchedFeed {
        if let amplification = entityAmplification(in: data) {
            jdnLog("fetch: \(feed.url.host ?? "?") declares \(amplification) — refused before parsing")
            throw FeedFetchError.parseFailureDetail("declares \(amplification)")
        }
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
        /// Capped: every candidate is held live until the item closes, and
        /// `pickBestImage` only ever needs a handful. An uncapped list is a
        /// place for a feed to put as many strings as it likes.
        static let maxImageCandidates = 24
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

        // **Attribute values count against the same budget as element text.**
        // `textDelivered` was incremented only from `foundCharacters` and
        // `foundCDATA`, so neither the per-element nor the per-document ceiling
        // saw an attribute at all. Measured: 31.8 MB of source, comfortably
        // under `markupLimit`, parsed in 12.65s while delivering 2.65 GB of
        // attribute value — `foundCharacters` saw 287 bytes of it.
        //
        // A single value over `maxAttributeValue` ends the parse on its own. No
        // real feed puts 8 KB in one attribute, and an entity expanded a few
        // hundred times inside a `url=` is exactly what this is for.
        for value in attributeDict.values {
            let bytes = value.utf8.count
            if bytes > Self.maxAttributeValue {
                jdnLog("fetch: \(feed.url.host ?? "?") sent a \(bytes)-byte attribute value — "
                       + "stopped parsing, keeping the \(items.count) item(s) so far")
                parser.abortParsing()
                return
            }
            textDelivered += bytes
        }
        if textDelivered > Self.maxDocumentText {
            jdnLog("fetch: \(feed.url.host ?? "?") delivered more than "
                   + "\(Self.maxDocumentText / 1024 / 1024) MB across text and attributes — "
                   + "stopped parsing, keeping the \(items.count) item(s) so far")
            parser.abortParsing()
            return
        }

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
                        if (current?.imageCandidates.count ?? 0) < ItemBuilder.maxImageCandidates {
                            current?.imageCandidates.append((href, width))
                        }
                    }
                }
            }
        case "enclosure":
            // RSS: <enclosure url="..." type="image/..."/>
            if let type = attributeDict["type"], type.hasPrefix("image/"),
               let url = attributeDict["url"] {
                if (current?.imageCandidates.count ?? 0) < ItemBuilder.maxImageCandidates {
                    current?.imageCandidates.append((url, 0))
                }
            }
        case "media:thumbnail", "media:content":
            if let url = attributeDict["url"] {
                let width = Int(attributeDict["width"] ?? "") ?? 0
                if (current?.imageCandidates.count ?? 0) < ItemBuilder.maxImageCandidates {
                    current?.imageCandidates.append((url, width))
                }
            }
        default:
            break
        }
    }

    /// Longest run of text this will hold for one element.
    ///
    /// `XMLParser` is SAX and accumulates nothing itself, so libxml2's own
    /// 10 MB text ceiling never applies: a `<channel><title>` of 200 MB of `A`
    /// parses as a **success** in 0.18 seconds across 203 `foundCharacters`
    /// callbacks, leaves a 209,715,200-character string, and takes 1.5 GB of
    /// resident memory with it. That title is then written into `feeds.json`
    /// and rewritten on every refresh thereafter.
    ///
    /// 64 KB is far more than any element in a feed needs — the largest real
    /// `content:encoded` in the subscribed set is under 5 MB and that is the
    /// whole document, not one element — and `Standfirst` clamps the body to
    /// 256 KB downstream regardless.
    private static let maxElementText = 64 * 1024

    /// Bytes of text accepted across the whole document.
    ///
    /// The per-element cap alone does not stop an entity-amplification feed:
    /// libxml2 rescans an entity value at every reference, so cost tracks the
    /// product of entity size and reference count regardless of how the text
    /// is distributed. Measured on this machine: 1 MB expanded 100,000 times,
    /// from a **1.5 MB** file, cost 59.2 seconds. A response-size limit cannot
    /// help at that ratio; a limit on how much text is delivered can.
    /// Most bytes one attribute value may carry.
    ///
    /// Generous — a long `srcset` or a data URI in an enclosure is the biggest
    /// legitimate case and neither approaches this — and far below what an
    /// entity expanded a few hundred times inside one `url=` produces.
    static let maxAttributeValue = 8 * 1024

    private static let maxDocumentText = 8 * 1024 * 1024

    private var textDelivered = 0

    /// Accepts text up to the ceilings, then stops the parse.
    ///
    /// Stopping rather than truncating quietly, because a document that has
    /// tried to deliver eight megabytes of element text is not a feed having a
    /// verbose day. Whatever parsed before this point is still kept, exactly
    /// as it is for a malformed feed.
    private func accept(_ text: String, _ parser: XMLParser) {
        textDelivered += text.utf8.count
        if textDelivered > Self.maxDocumentText {
            jdnLog("fetch: \(feed.url.host ?? "?") delivered more than "
                   + "\(Self.maxDocumentText / 1024 / 1024) MB of element text — "
                   + "stopped parsing, keeping the \(items.count) item(s) so far")
            parser.abortParsing()
            return
        }
        guard buffer.utf8.count < Self.maxElementText else { return }
        buffer.append(text)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        accept(string, parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            accept(s, parser)
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
                // Capped where it is parsed, not where it is drawn. This one
                // is written to `feeds.json` and rewritten on every refresh,
                // so an unbounded value is a permanent cost rather than a
                // passing one.
                channelTitle = String(text.prefix(FeedFetcher.maxStoredTitle))
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
            // A feed offering more than this is not a feed the paper can use.
            // The largest real one in the subscribed set is a few hundred
            // items; 40,000 arrives as a few hundred KB of gzip, because
            // `URLSession` inflates transparently and nothing here asks it not
            // to, so the wire size says nothing about the work.
            if items.count >= FeedFetcher.maxItemsPerFeed {
                jdnLog("fetch: \(feed.url.host ?? "?") offered more than "
                       + "\(FeedFetcher.maxItemsPerFeed) items — stopped at the cap")
                parser.abortParsing()
            }
        default:
            break
        }
    }

    // MARK: - Finalisation

    private func finalise(_ b: ItemBuilder) -> FeedItem? {
        let title = String(Standfirst.decodeEntities(b.title).trimmed
            .prefix(FeedFetcher.maxStoredTitle))
        guard !title.isEmpty else { return nil }
        guard let originalLink = URL(string: b.link.trimmingCharacters(in: .whitespacesAndNewlines)),
              // **`hasPrefix` is not a scheme test.** It admitted `httpx:`,
              // `http-custom:` and `https.zoommtg:`, all of which parse, and it
              // carried no private-host half at all — so a feed could persist a
              // link that Launch Services would later hand to whatever app
              // claims that scheme. `firstExternalURL`, one function away, has
              // always used exact equality. This is the same rule the rest of
              // the app uses, applied where the link first enters the store.
              WebURL.isAllowed(originalLink) else { return nil }

        let bodyHTML = !b.contentEncoded.isEmpty ? b.contentEncoded : b.description
        // Link aggregators (HN, Reddit, Lobste.rs, etc.) give you the
        // discussion URL where an article URL would be. For those, look in
        // the body HTML for the first external href and use that instead —
        // the target matters more than the meta-commentary.
        let link = resolveTargetURL(originalLink, in: bodyHTML)
        let summary = String(cleanSummary(Standfirst.extract(from: bodyHTML))
            .prefix(FeedFetcher.maxStoredSummary))
        let imageURL = pickBestImage(candidates: b.imageCandidates, bodyHTML: bodyHTML)

        // Undated items rank LAST on the front page rather than masquerading
        // as "newest" (Date()) which would dominate anything correctly dated.
        let date = parseDate(b.published, b.updated, b.pubDate) ?? Date.distantPast
        // The identity a feed offers, and the identity the paper uses.
        //
        // These used to be the same string, and a guid is public. So a hostile
        // feed could copy a `<guid>` verbatim from a target's feed XML, stamp
        // a `<pubDate>` a minute later, and the genuine story would never
        // reach a page: `AppStore` merges every feed's items into one array,
        // `EditionBuilder` sorts date-descending, and first-seen-wins dedupe
        // then drops the older copy — which is the real one. A few hundred
        // bytes to delete somebody else's article.
        //
        // Namespacing by `feed.id` makes that impossible: no feed can name
        // another feed's item. Cross-feed dedupe still works, because it runs
        // on the canonical LINK as well, and a link is a real syndication
        // signal an attacker cannot forge without pointing at the genuine
        // article.
        let offered = b.guid.isEmpty ? link.absoluteString : b.guid
        let itemId = FeedFetcher.namespacedID(offered, in: feed.id)
        let sourceTitle = feed.title?.isEmpty == false ? feed.title! : channelTitle

        return FeedItem(
            feedId: feed.id,
            itemId: itemId,
            title: title,
            link: link,
            summary: summary,
            imageURL: imageURL,
            publishedAt: FeedFetcher.clamped(date),
            section: feed.section,
            sourceTitle: sourceTitle,
            legacyItemId: offered
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
