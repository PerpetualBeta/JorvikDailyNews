import Foundation

/// Parses an OPML subscription list into candidate feed entries. Supports
/// nested `<outline>` categorisation: an outline without `xmlUrl` is treated
/// as a section whose title becomes the `section` of each feed entry
/// nested beneath it.
struct OPMLEntry {
    let url: URL
    let title: String?
    let section: String
}

/// Stateless, and `Sendable` so the parse can be handed to its own queue
/// without capturing a class across a concurrency boundary.
struct OPMLImporter: Sendable {

    /// Largest OPML file worth reading.
    ///
    /// A subscription list of 242 feeds exports at about 40 KB. This is two
    /// orders of magnitude above that and stops `Data(contentsOf:)` reading
    /// whatever it is pointed at.
    static let maxFileBytes = 4 * 1024 * 1024

    /// Most entries one file may contribute.
    static let maxEntries = 5000

    enum Failure: Error, CustomStringConvertible {
        case tooLarge(Int)
        case amplification(String)
        var description: String {
            switch self {
            case .tooLarge(let bytes):
                return "that file is \(bytes / 1024 / 1024) MB, which is larger than a subscription list should be"
            case .amplification(let why):
                return "that file \(why)"
            }
        }
    }

    /// Reads and parses, with the same guards the feed path has.
    ///
    /// **The feed parser runs an entity pre-scan and this did not**, while
    /// calling the same `XMLParser` — so the one XML document a person hands
    /// the app deliberately was the one with no protection. The cost is inside
    /// libxml2 regardless of what the delegate implements, and `AppStore` is
    /// `@MainActor`, so it was paid on the main thread with no way to cancel.
    ///
    /// Reached only by choosing a file, so it sits outside the feed threat
    /// model — but "the user picked it" is not the same as "the user wrote it",
    /// and an OPML file is exactly the kind of thing that gets passed around.
    func read(contentsOf url: URL) throws -> [OPMLEntry] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size, size > Self.maxFileBytes { throw Failure.tooLarge(size) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.count > Self.maxFileBytes { throw Failure.tooLarge(data.count) }
        if let why = FeedFetcher.entityAmplification(in: data) {
            jdnLog("opml: refused before parsing — \(why)")
            throw Failure.amplification(why)
        }
        return parse(data: data)
    }

    func parse(data: Data) -> [OPMLEntry] {
        let parser = XMLParser(data: data)
        let delegate = OPMLDelegate()
        delegate.limit = Self.maxEntries
        parser.delegate = delegate
        guard parser.parse() else { return delegate.entries }
        return delegate.entries
    }
}

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    var entries: [OPMLEntry] = []
    /// Stops a file contributing an unbounded number of subscriptions, each of
    /// which becomes a feed the app then fetches every hour.
    var limit = Int.max
    private var sectionStack: [String] = []
    // Parallel stack: true if the matching outline was a category (pushed
    // onto sectionStack), false if it was a feed (nothing to pop).
    private var wasCategory: [Bool] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        let xmlUrl = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"] ?? attributeDict["xmlURL"]
        let text = (attributeDict["text"] ?? attributeDict["title"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // `WebURL.isAllowed`, not a scheme test that resembles it. The old one
        // did not lowercase, so an uppercase `HTTP:` entry in an otherwise good
        // file was silently dropped with no message — a correctness bug as well
        // as a gap — and it had no private-host half, so such an entry became a
        // subscription that fails every hour for ever once BoundedFetch refuses
        // it. WebURL's own header already named this file among the sites it
        // consolidated.
        if let urlString = xmlUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: urlString),
           WebURL.isAllowed(url) {
            let section = sectionStack.last ?? "Imported"
            if entries.count >= limit {
                jdnLog("opml: more than \(limit) entries — stopped reading")
                parser.abortParsing()
                return
            }
            entries.append(OPMLEntry(url: url, title: text, section: section))
            wasCategory.append(false)
        } else {
            let name = (text?.isEmpty == false ? text! : "Imported")
            sectionStack.append(name)
            wasCategory.append(true)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == "outline" else { return }
        guard let wasCat = wasCategory.popLast() else { return }
        if wasCat { _ = sectionStack.popLast() }
    }
}
