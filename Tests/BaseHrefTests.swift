import Foundation

/// The injected `<base href>`, and the page's own.
///
/// Rung 4 of the extraction ladder writes raw fetched HTML to a temporary
/// file, so a document that keeps its own base tag resolves every relative
/// link and picture against the staging directory or against a host it chose.
enum BaseHrefTests {

    private static let base = URL(string: "https://example.com/news/story")!

    static func run() {
        T.suite("Base href: the injected tag goes in the head") {
            let out = BaseHref.apply(to: "<html><head><title>A</title></head><body>x</body></html>",
                                     base: base)
            T.expect(out.contains("<base href=\"https://example.com/news/story\">"), "it is there")
            T.expect(out.range(of: "<base")!.lowerBound < out.range(of: "<title")!.lowerBound,
                     "before anything else in the head")
            // Never before the doctype: that would drop the parser into quirks
            // mode and change the DOM Readability is about to read.
            let doctyped = BaseHref.apply(to: "<!doctype html><html><head></head></html>", base: base)
            T.expect(doctyped.hasPrefix("<!doctype html>"), "the doctype still comes first")
        }

        T.suite("Base href: the page's own base is removed") {
            // Going first in the head is not enough. The spec's "before head"
            // insertion mode treats a <base> start tag as "anything else": it
            // opens an implied <head>, puts the base in it, and the later
            // explicit <head> is a parse error and ignored. So the page's base
            // is first in tree order however we inject ours.
            let early = BaseHref.apply(to: "<html><base href=\"https://evil.example/\">"
                                         + "<head></head><body>x</body></html>", base: base)
            T.expect(!early.contains("evil.example"), "a base before the head is gone")
            T.expect(early.contains("https://example.com/news/story"), "and ours is there")

            let inHead = BaseHref.apply(to: "<html><head><base href=\"https://evil.example/\">"
                                          + "</head></html>", base: base)
            T.expect(!inHead.contains("evil.example"), "and so is one inside the head")

            // The textual insertion has no idea what a comment is, so a page
            // opening with the literal string swallowed the injected tag.
            let commented = BaseHref.apply(to: "<!-- <head> is written here -->"
                                             + "<html><head></head></html>", base: base)
            T.expect(commented.contains("https://example.com/news/story"),
                     "a comment holding <head does not lose ours")
        }

        T.suite("Base href: stripping is linear and knows its own tag name") {
            T.equal(BaseHref.stripped("<p>x</p>"), "<p>x</p>", "a document with none is untouched")
            T.expect(BaseHref.stripped("<basefont color=\"red\">").contains("basefont"),
                     "<basefont> is a different element")
            T.expect(BaseHref.stripped("<p>baseball</p>").contains("baseball"),
                     "and <baseball> is not one at all")
            T.equal(BaseHref.stripped("a<base href=\"x\">b"), "ab", "the tag and nothing else")

            // `<base\b[^>]*>` is quadratic on this: every start position
            // rescans to the end looking for a `>` that is not there. A
            // hundred thousand of them is a second of CPU under a pattern and
            // nothing at all under a scan that always advances.
            let bomb = String(repeating: "<base ", count: 100_000)
            let started = Date()
            _ = BaseHref.stripped(bomb)
            T.expect(Date().timeIntervalSince(started) < 2.0, "an unclosed run does not hang")
        }
    }
}
