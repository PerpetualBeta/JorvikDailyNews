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

        T.suite("Walker: a namespace prefix does not survive sanitising") {
            func source(_ inner: String) -> String {
                (walk("<svg width=\"400\" height=\"300\">\(inner)</svg>").first?["svg"] as? String) ?? ""
            }
            // tagName keeps the prefix, so the drop-list matched nothing and a
            // prefixed script came through verbatim.
            let prefixed = source("<svg:script>fetch('http://127.0.0.1:1/')</svg:script><rect/>")
            T.expect(!prefixed.lowercased().contains("script"), "a prefixed script is removed")
            T.expect(prefixed.contains("<rect"), "and the drawing survives")
            let fo = source("<s:foreignObject><iframe src=\"http://x/\"></iframe></s:foreignObject><rect/>")
            T.expect(!fo.lowercased().contains("foreignobject"), "a prefixed foreignObject too")
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

        T.suite("Walker: a figure that holds an article is not a picture") {
            // The Guardian writes its "Key Takeaways" pieces as a <figure>
            // wrapping the whole article in an <ol>. `getElementsByTagName`
            // looks at every descendant, so emitFigure found the one
            // photograph nested inside a list item, emitted that, and returned
            // — taking 42 paragraphs and 7 headings with it, silently, with
            // nothing recorded in `dropped`. One live article extracted 13,791
            // characters of text and rendered as a single photograph.
            let article = "<figure><ol><li><h2>1. First part</h2>"
                + "<p>Alpha prose.</p><p>Beta prose.</p></li>"
                + "<li><h2>2. Second part</h2><p>Gamma prose.</p></li></ol></figure>"
            let out = walk(article)
            T.equal(kinds(out), ["heading", "paragraph", "paragraph", "heading", "paragraph"],
                    "every heading and paragraph survives, in order")
            T.equal(text(out[0]), "1. First part", "and the numbering the page wrote is kept")

            // An ordinary photograph is untouched, including Ars Technica's
            // shape, which wraps the image in <div><p><a>. A <p> inside a
            // figure is picture furniture, not prose: counting it as prose
            // made the caption come out twice over, with a "Credit:" line.
            let ars = "<figure><div><p><a href=\"https://e.com/big.jpg\">"
                + "<img src=\"https://e.com/small.jpg\"></a></p></div>"
                + "<figcaption>A rocket lifting off.</figcaption></figure>"
            let picture = walk(ars)
            T.equal(kinds(picture), ["image"], "still exactly one block")
            T.equal((picture[0]["caption"] as? [[String: Any]] ?? [])
                        .map { $0["text"] as? String ?? "" }.joined(),
                    "A rocket lifting off.", "with its caption still attached")

            let plain = walk("<figure><img src=\"https://e.com/a.png\">"
                             + "<figcaption>Cap.</figcaption></figure>")
            T.equal(kinds(plain), ["image"], "and so is the simple shape")
        }

        T.suite("Walker: a list of sections is not a list") {
            // A heading inside an <li> is the signal. A real bulleted list does
            // not have an <h2> in it; an article broken into numbered parts
            // almost always does. Flattened, the whole piece arrived as one
            // block of welded text with every heading gone.
            let sections = "<ol><li><h2>1. One</h2><p>Alpha.</p></li>"
                + "<li><h2>2. Two</h2><p>Beta.</p></li></ol>"
            T.equal(kinds(walk(sections)), ["heading", "paragraph", "heading", "paragraph"],
                    "walked as sections, not flattened into items")

            // Ordinary lists are untouched.
            let ordinary = walk("<ul><li>One</li><li>Two</li><li>Three</li></ul>")
            T.equal(kinds(ordinary), ["list"], "a plain list is still a list")
            T.equal((ordinary[0]["items"] as? [[String: Any]] ?? []).count, 3, "with its three items")

            // And a list item of several paragraphs — a Lobsters comment — is
            // still one item, because that IS a list entry. Deliberately not
            // keyed on paragraph count.
            let comment = walk("<ul><li><p>First para.</p><p>Second para.</p></li></ul>")
            T.equal(kinds(comment), ["list"], "several paragraphs do not make it sections")
            T.equal((comment[0]["items"] as? [[String: Any]] ?? []).count, 1, "and it is one item")
        }

        T.suite("Walker: classifying a figure or a list never loses one") {
            // Both classifiers give up after a node budget, and they have to
            // give up in opposite directions. For a figure, "container" costs
            // only the caption pairing. For a list it costs the list itself:
            // 2,000 nodes is about 1,000 <li> that each wrap a <span>, so an
            // ordinary changelog or index lost every bullet and every number
            // and read as undifferentiated prose, with nothing hostile
            // involved.
            let wrapped = "<ul>" + String(repeating: "<li><span>q</span></li>", count: 1200) + "</ul>"
            let out = walk(wrapped)
            T.equal(kinds(out), ["list"], "a long list of wrapped items is still a list")
            T.equal((out.first?["items"] as? [[String: Any]] ?? []).count, 1200, "with all its items")

            // A gallery is picture furniture, not prose. Routed to the
            // container path, `collectItems` calls only `runsOf`, which has no
            // IMG case, so every picture was discarded without even a drop().
            let gallery = "<figure><ul><li><img src=\"https://e.com/1.jpg\"></li>"
                + "<li><img src=\"https://e.com/2.jpg\"></li></ul><figcaption>Cap</figcaption></figure>"
            T.equal(kinds(walk(gallery)), ["image"], "a gallery figure still yields its picture")

            // And a heading in a figure is a chart title, not an article, so
            // the caption stays paired with the picture.
            let chart = "<figure><h2>Chart 1</h2><img src=\"https://e.com/c.png\">"
                + "<figcaption>C</figcaption></figure>"
            T.equal(kinds(walk(chart)), ["image"], "a chart figure keeps its pairing")
        }

        T.suite("Walker: block contents have a ceiling too") {
            // The count ceiling above says nothing about what is inside one
            // block, and one <pre> holding megabytes on one line is one
            // element, so it walked straight past it. The cost is
            // `NSLayoutManager.ensureLayout` on the main thread, about 0.27 s
            // per MB, re-run on every size proposal.
            let cap = 64 * 1024

            let hugePre = "<pre>" + String(repeating: "x", count: cap + 5000) + "</pre>"
            let pre = walk(hugePre)
            T.equal(pre.count, 1, "still one code block")
            T.expect((pre.first?["text"] as? String ?? "").count <= cap,
                     "and its text is cut to the ceiling")

            // A linked paragraph is the expensive shape, because a run
            // carrying an href is what becomes a ProseText.
            let hugeLink = "<p><a href=\"https://e.com/\">"
                + String(repeating: "y", count: cap + 5000) + "</a></p>"
            T.expect(text(walk(hugeLink).first ?? [:]).count <= cap,
                     "a single linked run is cut too")

            // The budget is shared across a whole list, not spent per item.
            let bulk = String(repeating: "z", count: 1000)
            let list = "<ul>" + String(repeating: "<li>\(bulk)</li>", count: 200) + "</ul>"
            let listBlocks = walk(list)
            T.equal(listBlocks.count, 1, "one list block")
            T.expect(text(listBlocks[0]).count <= cap, "whose items together fit the ceiling")

            // And count is bounded separately, because 30,000 single-character
            // items are well under the character budget and still 30,000 views.
            // Assert the block is a list BEFORE counting its items. This
            // assertion used to pass vacuously: 2,500 items tripped the
            // classifier's node limit, the list was redrawn as 2,500
            // paragraphs, `items` was nil, and `[].count <= 2000` was true.
            let many = "<ul>" + String(repeating: "<li>q</li>", count: 2500) + "</ul>"
            let manyOut = walk(many)
            T.equal(kinds(manyOut), ["list"], "2,500 items is still one list")
            T.equal((manyOut.first?["items"] as? [[String: Any]] ?? []).count, 2000,
                    "cut to the item ceiling, not silently re-shaped")

            let cells = String(repeating: "<td>\(bulk)</td>", count: 20)
            let table = "<table>" + String(repeating: "<tr>\(cells)</tr>", count: 200) + "</table>"
            let rows = walk(table).first?["rows"] as? [[[[String: Any]]]] ?? []
            T.expect(rows.count < 200, "a bulk table loses its later rows")
            T.expect(rows.count > 0, "and keeps its first ones")

            // An ordinary article notices none of this.
            let ordinary = "<p>Some ordinary prose.</p><ul><li>One</li><li>Two</li></ul>"
            T.equal(kinds(walk(ordinary)), ["paragraph", "list"], "normal markup is untouched")
            T.equal(text(walk(ordinary)[1]), "OneTwo", "with its items whole")
        }

        T.suite("Walker: the ceiling counts UTF-16 and never cuts a pair") {
            let cap = 64 * 1024
            // A cut by raw UTF-16 index can end on a lone high surrogate.
            // `JSON.stringify` emits that happily as a \\ud83d escape, and
            // Swift's JSONDecoder then rejects the WHOLE article with "Missing
            // low code point in surrogate pair" — so one emoji landing on the
            // 65,536th unit turned a page that extracted perfectly into no
            // article at all. Every other case in this file is BMP ASCII,
            // which is why they all passed with this open.
            let onCeiling = String(repeating: "a", count: cap - 1)
                + String(repeating: "\u{1F600}", count: 10)
            for (what, html) in [("a paragraph", "<p>" + onCeiling + "</p>"),
                                 ("a <pre>", "<pre>" + onCeiling + "</pre>"),
                                 ("a loose text node", "<article>" + onCeiling + "</article>")] {
                let out = walk(html)
                T.expect(!out.isEmpty, "\(what) still produces a block")
                let body = (out[0]["text"] as? String) ?? text(out[0])
                T.expect(body.utf16.count <= cap, "\(what) is inside the ceiling")
                T.expect(body.unicodeScalars.allSatisfy { $0.value < 0xD800 || $0.value > 0xDFFF },
                         "\(what) carries no lone surrogate")
            }
        }

        T.suite("Walker: a loose text node is budgeted like everything else") {
            // The one `blocks.push` that bypassed the budget. A bare text node
            // is not an element, so the 60,000-element and depth guards are
            // blind to it too.
            let bulk = String(repeating: "x", count: 300_000)
            for parent in ["article", "section", "div"] {
                let out = walk("<" + parent + "><p>Intro.</p>" + bulk + "<p>Tail.</p></" + parent + ">")
                let longest = out.map { text($0).utf16.count }.max() ?? 0
                T.expect(longest <= 64 * 1024,
                         "loose text under <\(parent)> is cut, longest block \(longest)")
            }
        }

        T.suite("Walker: an absurd image source is refused") {
            // `ReaderLede.key` percent-decodes every src on every body pass.
            let long = "<img src=\"data:image/png;base64,"
                + String(repeating: "A", count: 128 * 1024) + "\">"
            T.equal(walk(long).count, 0, "a src past the ceiling emits no block")
            let fine = "<img src=\"https://e.com/a.png\">"
            T.equal(kinds(walk(fine)), ["image"], "an ordinary one is kept")
        }

        T.suite("Walker: a quote keeps its pictures") {
            // Every image inside a blockquote used to be dropped: a quote was
            // text and nothing else. thedailywtf.com puts each screenshot in
            // `<blockquote><p><a href="#id"><img></a></p></blockquote>`, so
            // the reader showed that article's captions with no pictures at
            // all while Safari showed six.
            let img = "<img src=\"https://cdn.example.com/shot.png\" alt=\"a\"/>"
            func kindsFor(_ inner: String) -> [String] {
                kinds(walk("<p>Lead in.</p>" + inner + "<p>Tail.</p>"))
            }
            T.expect(kindsFor("<blockquote>\(img)</blockquote>").contains("image"),
                     "an image directly in a quote")
            T.expect(kindsFor("<blockquote><p>\(img)</p></blockquote>").contains("image"),
                     "wrapped in a paragraph")
            T.expect(kindsFor("<blockquote><p><a href=\"#x\">\(img)</a></p><p> </p></blockquote>")
                        .contains("image"), "the shape thedailywtf.com actually uses")
            // The quote's own text still comes through, and still first.
            let both = kindsFor("<blockquote><p>Said the thing.</p>\(img)</blockquote>")
            T.expect(both.contains("quote"), "the quote text survives")
            if let q = both.firstIndex(of: "quote"), let i = both.firstIndex(of: "image") {
                T.expect(q < i, "text before picture")
            }
            // A quote with no picture is unchanged.
            T.equal(kindsFor("<blockquote><p>Just words.</p></blockquote>"),
                    ["paragraph", "quote", "paragraph"], "a plain quote is untouched")
        }

        T.suite("Walker: relative sources are left for the caller to resolve") {
            // The walker emits `src` as written. Resolution happens in Swift
            // against the page's own <base href> when it declares one, which is
            // what unsung.aresluna.org needed: `<base href="/">` with pictures
            // written `_media/…/1.avif`. Against the document address those
            // became `…/the-pc-side/_media/…` and returned 404, three for three.
            let out = walk("<p>Words.</p><img src=\"_media/pic/1.avif\" alt=\"a\"/>")
            let src = out.first(where: { ($0["kind"] as? String) == "image" })?["src"] as? String
            T.equal(src, "_media/pic/1.avif", "passed through unchanged")
        }

        T.suite("Walker: an absurd SVG size is refused") {
            // A size is a number the page chooses, and it reaches the reader's
            // layout. `width="0.0000001" height="1e308"` is a hundred bytes.
            for bad in ["width=\"0.0000001\" height=\"1e308\"",
                        "width=\"1e400\" height=\"400\"",
                        "width=\"-400\" height=\"-300\"",
                        "width=\"999999\" height=\"400\""] {
                let out = walk("<svg \(bad)><rect width=\"10\" height=\"10\"/></svg>")
                T.expect(!kinds(out).contains("svg"), "refused: \(bad)")
            }
            T.expect(kinds(walk("<svg width=\"400\" height=\"300\"><rect/></svg>")).contains("svg"),
                     "an ordinary diagram is kept")
        }

        T.suite("Walker: nothing to walk") {
            T.expect(walk("").isEmpty, "empty input, no blocks")
            T.expect(walk("<div></div>").isEmpty, "an empty container yields nothing")
            T.expect(walk("   \n  ").isEmpty, "whitespace only")
        }
    }
}
