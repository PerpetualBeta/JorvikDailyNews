import Foundation

/// The OPML importer's guards.
///
/// It parses an untrusted file with the same `XMLParser` the feed path uses,
/// and had none of the feed path's protection — so the one XML document a
/// person hands the app deliberately was the one with nothing in front of it.
enum OPMLImportTests {

    private static func opml(_ body: String, doctype: String = "") -> Data {
        Data(("<?xml version=\"1.0\"?>\n" + doctype
              + "<opml version=\"1.0\"><body>" + body + "</body></opml>").utf8)
    }

    private static func outline(_ n: Int) -> String {
        (0..<n).map { "<outline type=\"rss\" text=\"F\($0)\" xmlUrl=\"https://e.com/\($0).xml\"/>" }
            .joined()
    }

    static func run() {
        T.suite("OPML: an ordinary list imports") {
            let entries = OPMLImporter().parse(data: opml(outline(3)))
            T.equal(entries.count, 3, "three feeds")
            T.equal(entries.first?.url.absoluteString, "https://e.com/0.xml", "first url")
        }

        T.suite("OPML: the entry count has a ceiling") {
            let entries = OPMLImporter().parse(data: opml(outline(OPMLImporter.maxEntries + 200)))
            T.expect(entries.count <= OPMLImporter.maxEntries,
                     "stopped at the ceiling, got \(entries.count)")
            T.expect(entries.count > OPMLImporter.maxEntries - 50, "and not far short of it")
        }

        T.suite("OPML: an entity bomb is refused before parsing") {
            // The same guard the feed path runs, on the same bytes, now shared
            // rather than copied.
            let value = String(repeating: "A", count: 4096)
            let bomb = opml("<outline text=\"&big;\" xmlUrl=\"https://e.com/a.xml\"/>",
                            doctype: "<!DOCTYPE opml [<!ENTITY big \"\(value)\">]>\n")
            T.expect(FeedFetcher.entityAmplification(in: bomb) != nil,
                     "the shared guard sees it")
            // And an ordinary file is not refused.
            T.expect(FeedFetcher.entityAmplification(in: opml(outline(2))) == nil,
                     "an ordinary list passes")
        }

        T.suite("OPML: sections and bad entries") {
            let nested = "<outline text=\"Tech\">" + outline(2) + "</outline>"
            let entries = OPMLImporter().parse(data: opml(nested))
            T.equal(entries.count, 2, "nested feeds found")
            T.equal(entries.first?.section, "Tech", "the category becomes the section")
            // Anything that is not an http(s) URL is skipped rather than stored.
            let bad = "<outline type=\"rss\" text=\"X\" xmlUrl=\"file:///etc/passwd\"/>"
            T.expect(OPMLImporter().parse(data: opml(bad)).isEmpty, "a file:// entry is skipped")
        }
    }
}
