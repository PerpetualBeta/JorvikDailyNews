import Foundation
import JavaScriptCore

/// Tests for `Resources/ReaderBlocks.js`, the JavaScript that turns an
/// article's HTML into typed blocks.
///
/// This exists because **every walker bug so far was found by dumping blocks
/// by hand** — the cultofmac collapse, the welded standfirst, the welded
/// Lobsters comment. Three defects, all in shipped code, all invisible in the
/// rendering, and none of them reachable by a Swift test until now.
///
/// `__jdnBlocks` takes an HTML string and parses it itself, so Readability is
/// not involved and the fixtures can be a few lines each. That matters: a
/// fixture big enough to satisfy Readability would test two things at once and
/// tell us which one broke only by accident.
enum WalkerTests {

    // MARK: - The harness

    private static let context: JSContext? = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        guard let ctx = JSContext() else { return nil }
        var failures: [String] = []
        ctx.exceptionHandler = { _, e in failures.append(e?.toString() ?? "?") }

        // LinkeDOM wants a couple of browser globals that JavaScriptCore does
        // not provide. The app installs the same two.
        let decode: @convention(block) (String) -> String? = { input in
            var p = input.trimmingCharacters(in: .whitespacesAndNewlines)
            while p.count % 4 != 0 { p += "=" }
            guard let d = Data(base64Encoded: p, options: [.ignoreUnknownCharacters]) else { return nil }
            return String(decoding: d.map { UInt16($0) }, as: UTF16.self)
        }
        ctx.setObject(decode, forKeyedSubscript: "atob" as NSString)
        let resolve: @convention(block) (String, String?) -> String? = { rel, base in
            URL(string: rel, relativeTo: base.flatMap { URL(string: $0) })?
                .absoluteURL.absoluteString
        }
        ctx.setObject(resolve, forKeyedSubscript: "__jdnResolve" as NSString)
        ctx.evaluateScript("""
        var console = { log: function(){}, warn: function(){}, error: function(){},
                        info: function(){}, debug: function(){} };
        globalThis.URL = function (input, base) {
          var href = __jdnResolve(String(input), base === undefined ? null : String(base));
          if (!href) throw new TypeError('Invalid URL: ' + input);
          this.href = href; this.toString = function(){ return this.href; };
        };
        """)
        for file in ["LinkeDOM.js", "ReaderBlocks.js"] {
            guard let js = try? String(contentsOf: root.appendingPathComponent(file),
                                       encoding: .utf8) else {
                failures.append("missing \(file)")
                continue
            }
            ctx.evaluateScript(js)
        }
        guard failures.isEmpty else { return nil }
        return ctx
    }()

    /// Blocks for a scrap of article HTML.
    private static func walk(_ html: String, minSvgSide: Double = 64) -> [[String: Any]] {
        guard let ctx = context,
              let out = ctx.objectForKeyedSubscript("__jdnBlocks")?
                  .call(withArguments: [html, minSvgSide])?.toString(),
              let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["blocks"] as? [[String: Any]]
        else { return [] }
        return blocks
    }

    private static func kinds(_ blocks: [[String: Any]]) -> [String] {
        blocks.map { $0["kind"] as? String ?? "?" }
    }

    /// All the text of a block, runs joined, including list items.
    private static func text(_ block: [String: Any]) -> String {
        var runs = block["runs"] as? [[String: Any]] ?? []
        for item in block["items"] as? [[String: Any]] ?? [] {
            runs += item["runs"] as? [[String: Any]] ?? []
        }
        return runs.map { $0["text"] as? String ?? "" }.joined()
    }

    private static func items(_ blocks: [[String: Any]]) -> [[String: Any]] {
        blocks.flatMap { $0["items"] as? [[String: Any]] ?? [] }
    }

    // MARK: - Suites

    static func run() {
        T.suite("Walker: the harness loads at all") {
            T.expect(context != nil, "LinkeDOM and ReaderBlocks evaluated")
            T.equal(kinds(walk("<p>Hello.</p>")), ["paragraph"], "and walks a paragraph")
        }

        T.suite("Walker: a nested html/body is recursed into") {
            // cultofmac.com nests a whole <html><body> inside the article
            // content. The container test was an allow-list of block tags with
            // HTML and BODY absent, so the section looked as though it had no
            // block children and 9,893 characters came out as one paragraph.
            let html = "<section><html><body><p>One.</p><p>Two.</p><h2>Three</h2>"
                     + "<p>Four.</p></body></html></section>"
            T.equal(kinds(walk(html)), ["paragraph", "paragraph", "heading", "paragraph"],
                    "four blocks, not one")
        }

        T.suite("Walker: an unknown container is recursed into") {
            // The general form of the same bug. The test is now what is NOT
            // inline, so a tag nobody thought of behaves correctly.
            T.equal(kinds(walk("<custom-wrapper><p>One.</p><p>Two.</p></custom-wrapper>")),
                    ["paragraph", "paragraph"], "an unknown element is a container")
        }

        T.suite("Walker: a container of only inline content is a paragraph") {
            T.equal(kinds(walk("<div>Just <em>some</em> words.</div>")), ["paragraph"],
                    "not lost, and not split")
            T.equal(text(walk("<div>Just <em>some</em> words.</div>")[0]),
                    "Just some words.", "with its text intact")
        }

        T.suite("Walker: inline tags introduce no space") {
            // Replacing an inline tag with a space is what put the gap in
            // "the famous Doppler effect ."
            T.equal(text(walk("<p>the famous <em>Doppler</em> effect.</p>")[0]),
                    "the famous Doppler effect.", "no stray spaces")
            T.equal(text(walk("<p>a<b>b</b>c</p>")[0]), "abc", "nor between adjacent runs")
        }

        T.suite("Walker: paragraphs inside a list item are broken") {
            // A Lobsters comment read "...nothing to do with it.I don't
            // agree..." — two paragraphs of one comment, welded.
            let out = items(walk("<ul><li><p>First para.</p><p>Second para.</p></li></ul>"))
            T.equal(out.count, 1, "still one item")
            let body = (out[0]["runs"] as? [[String: Any]] ?? [])
                .map { $0["text"] as? String ?? "" }.joined()
            T.expect(!body.contains("para.Second"), "not welded")
            T.expect(body.contains("\n\n"), "a paragraph break is present")
        }

        T.suite("Walker: a well-formed page gains no stray breaks") {
            // The other half of that fix: pages whose paragraphs are already
            // separate blocks must be untouched. Measured across four real
            // articles at the time — cultofmac, phys.org, BBC, littletheta —
            // all four gained exactly zero.
            let out = walk("<p>One.</p><p>Two.</p><ul><li>Item</li></ul>")
            T.expect(!out.contains { text($0).contains("\n\n") },
                     "no paragraph marks where nothing was welded")
        }

        T.suite("Walker: nested lists carry their depth") {
            // Walking a nested list as text welded its items onto the parent's:
            // "First itemNested oneNested two", no separator and no bullets.
            let out = items(walk("<ul><li>Top<ul><li>Middle<ul><li>Bottom</li></ul></li></ul></li></ul>"))
            T.equal(out.count, 3, "three items")
            T.equal(out.map { $0["depth"] as? Int ?? -1 }, [0, 1, 2], "depths 0, 1, 2")
            // Each item's OWN text, not the block's — `text(_:)` joins every
            // item, so asking it about welding would only test the helper.
            func body(_ item: [String: Any]) -> String {
                (item["runs"] as? [[String: Any]] ?? [])
                    .map { $0["text"] as? String ?? "" }.joined()
            }
            T.equal(out.map(body), ["Top", "Middle", "Bottom"],
                    "each item holds only its own text")
        }

        T.suite("Walker: ordered lists number from one") {
            let out = items(walk("<ol><li>a</li><li>b</li><li>c</li></ol>"))
            T.equal(out.map { $0["index"] as? Int ?? -1 }, [1, 2, 3], "1, 2, 3")
            T.expect(out.allSatisfy { $0["ordered"] as? Bool == true }, "all ordered")
            T.expect(items(walk("<ul><li>a</li></ul>")).allSatisfy { $0["ordered"] as? Bool == false },
                     "an unordered list is not")
        }

        T.suite("Walker: links keep their address") {
            let runs = walk("<p>See <a href=\"/other\">this page</a> for more.</p>")[0]["runs"]
                as? [[String: Any]] ?? []
            let linked = runs.filter { $0["href"] is String }
            T.equal(linked.count, 1, "one linked run")
            T.equal(linked.first?["href"] as? String, "/other", "href carried verbatim")
            T.equal(linked.first?["text"] as? String, "this page", "over the right text")
        }

        T.suite("Walker: structure that is not prose") {
            T.equal(kinds(walk("<h1>Title</h1>")), ["heading"], "heading")
            T.equal(walk("<h3>T</h3>")[0]["level"] as? Int, 3, "at its own level")
            T.equal(kinds(walk("<blockquote><p>Quoted.</p></blockquote>")), ["quote"], "quote")
            T.equal(kinds(walk("<pre><code>let x = 1</code></pre>")), ["code"], "code")
            T.equal(walk("<pre><code>let x = 1</code></pre>")[0]["text"] as? String,
                    "let x = 1", "code text kept verbatim")
            T.equal(kinds(walk("<table><tr><td>a</td><td>b</td></tr></table>")), ["table"], "table")
            T.equal(kinds(walk("<img src=\"/a.jpg\">")), ["image"], "image")
            T.equal(walk("<img src=\"/a.jpg\" alt=\"An alt\">")[0]["alt"] as? String,
                    "An alt", "with its alt text")
        }

        T.suite("Walker: a figure keeps its caption with its picture") {
            let out = walk("<figure><img src=\"/a.jpg\"><figcaption>The caption.</figcaption></figure>")
            T.equal(kinds(out), ["image"], "one image block")
            let caption = (out[0]["caption"] as? [[String: Any]] ?? [])
                .map { $0["text"] as? String ?? "" }.joined()
            T.equal(caption, "The caption.", "caption attached, not left as prose")
        }

        T.suite("Walker: inline SVG above the size threshold") {
            // Small SVGs are icons and decorations; a large one is a diagram
            // and is drawn. The threshold is a side in points.
            let big = "<svg width=\"400\" height=\"300\"><rect width=\"10\" height=\"10\"/></svg>"
            let small = "<svg width=\"16\" height=\"16\"><rect width=\"4\" height=\"4\"/></svg>"
            T.equal(kinds(walk(big)), ["svg"], "a 400x300 diagram is kept")
            T.expect(!kinds(walk(small)).contains("svg"), "a 16x16 icon is not")
        }

        // The SVG a feed sends is drawn by AppKit's private `_NSSVGImageRep`,
        // closed code whose willingness to resolve an external reference is a
        // property of the OS. It resolved none of these on macOS 26.6.2 —
        // measured, on one OS, on one day, against a deployment target of
        // macOS 14. These tests are why that no longer has to be re-measured.
        T.suite("Walker: an SVG cannot reach outside itself") {
            func svg(_ inner: String) -> String {
                "<svg width=\"400\" height=\"300\">\(inner)</svg>"
            }
            func source(_ inner: String) -> String {
                (walk(svg(inner)).first?["svg"] as? String) ?? ""
            }

            let script = source("<script>fetch('http://127.0.0.1:1/x')</script><rect/>")
            T.expect(!script.lowercased().contains("<script"), "script is removed")
            T.expect(script.contains("<rect"), "and the drawing survives it")

            let handler = source("<rect onload=\"fetch('http://127.0.0.1:1/x')\"/>")
            T.expect(!handler.lowercased().contains("onload"), "an event handler is removed")
            T.expect(handler.contains("<rect"), "the element itself stays")

            for attribute in ["href", "xlink:href"] {
                let out = source("<image \(attribute)=\"http://127.0.0.1:1/x.png\" width=\"10\" height=\"10\"/>")
                T.expect(!out.contains("127.0.0.1"), "\(attribute) to a URL is removed")
            }
            let file = source("<image href=\"file:///etc/passwd\" width=\"10\" height=\"10\"/>")
            T.expect(!file.contains("etc/passwd"), "a file:// reference is removed")

            let imported = source("<style>@import url('http://127.0.0.1:1/x.css');</style><rect/>")
            T.expect(!imported.lowercased().contains("@import"), "a stylesheet import is removed")

            let external = source("<rect fill=\"url(http://127.0.0.1:1/x)\"/>")
            T.expect(!external.contains("127.0.0.1"), "an external url() in a presentation attribute goes")

            let styled = source("<rect style=\"fill:url('http://127.0.0.1:1/x')\"/>")
            T.expect(!styled.contains("127.0.0.1"), "and one in a style attribute")

            let foreign = source("<foreignObject><iframe src=\"http://127.0.0.1:1/\"></iframe></foreignObject><rect/>")
            T.expect(!foreign.lowercased().contains("foreignobject"), "foreignObject is removed whole")
            T.expect(!foreign.lowercased().contains("iframe"), "taking its iframe with it")
        }

        T.suite("Walker: sanitising keeps what a real diagram needs") {
            func source(_ inner: String) -> String {
                (walk("<svg width=\"400\" height=\"300\">\(inner)</svg>").first?["svg"] as? String) ?? ""
            }
            // `<use href="#id">` is how half of real diagrams are built, and a
            // data: image is self-contained. Stripping either would make the
            // sanitiser worse than the problem.
            let fragment = source("<defs><rect id=\"a\" width=\"10\" height=\"10\"/></defs><use href=\"#a\"/>")
            T.expect(fragment.contains("#a"), "a fragment reference is kept")

            let data = source("<image href=\"data:image/png;base64,iVBORw0KGgo=\" width=\"10\" height=\"10\"/>")
            T.expect(data.contains("data:image/png"), "a data: URI is kept")

            let fill = source("<defs><linearGradient id=\"g\"/></defs><rect fill=\"url(#g)\"/>")
            T.expect(fill.contains("url(#g)"), "a url(#fragment) fill is kept")

            let styles = source("<style>.a{fill:red}</style><rect class=\"a\"/>")
            T.expect(styles.contains("fill:red"), "a stylesheet with no external reference is kept")

            let plain = source("<rect width=\"10\" height=\"10\" fill=\"blue\"/>")
            T.expect(plain.contains("fill=\"blue\""), "ordinary attributes are untouched")
            T.expect(plain.hasPrefix("<svg"), "and the result is still an svg element")
        }

        T.suite("Walker: the block count has a ceiling") {
            // Every block carrying a link becomes an NSTextView whose layout is
            // forced synchronously, so an unbounded count is a force-quit a
            // page can choose. 40,000 short linked paragraphs walk from 3.66 MB
            // of HTML in under seven seconds — inside the watchdog, so they are
            // returned rather than abandoned.
            let many = String(repeating: "<p><a href=\"https://e.com/\">x</a></p>", count: 4200)
            let out = walk(many)
            T.expect(out.count <= 4000, "truncated to the ceiling, got \(out.count)")
            T.expect(out.count > 3900, "and not to something much smaller")
            // An ordinary article is untouched. The longest this pipeline has
            // produced from a live page is 563.
            let ordinary = String(repeating: "<p>Some ordinary prose here.</p>", count: 600)
            T.equal(walk(ordinary).count, 600, "600 blocks pass through whole")
        }

        T.suite("Walker: nothing to walk") {
            T.expect(walk("").isEmpty, "empty input, no blocks")
            T.expect(walk("<div></div>").isEmpty, "an empty container yields nothing")
            T.expect(walk("   \n  ").isEmpty, "whitespace only")
        }
    }
}
