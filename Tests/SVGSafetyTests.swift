import Foundation

/// The far-side check on stored SVG.
///
/// The walker sanitises at capture, so in normal running this sees only clean
/// source. It exists for editions written before the walker did, which the app
/// reads every day.
enum SVGSafetyTests {

    private static func svg(_ inner: String) -> String {
        "<svg width=\"400\" height=\"300\">\(inner)</svg>"
    }

    static func run() {
        T.suite("SVG safety: what is refused") {
            let cases: [(String, String)] = [
                ("a script element", "<script>fetch('http://127.0.0.1:1/')</script>"),
                ("a foreignObject", "<foreignObject><p>x</p></foreignObject>"),
                ("an iframe", "<iframe src=\"http://127.0.0.1:1/\"></iframe>"),
                ("a stylesheet import", "<style>@import url('http://x/y.css');</style>"),
                ("an onload handler", "<rect onload=\"fetch('http://x')\"/>"),
                ("an onclick handler", "<rect onclick=\"x()\"/>"),
                ("a spaced handler", "<rect onbegin = \"x()\"/>"),
                ("an http image", "<image href=\"http://127.0.0.1:1/x.png\"/>"),
                ("an https image", "<image href=\"https://example.com/x.png\"/>"),
                ("a file reference", "<image href=\"file:///etc/passwd\"/>"),
                ("an xlink href", "<image xlink:href=\"http://x/y.png\"/>"),
                ("an external url()", "<rect fill=\"url(http://x/y)\"/>"),
                ("an external url() in style", "<rect style=\"fill:url('https://x/y')\"/>"),
            ]
            for (what, inner) in cases {
                T.expect(SVGSafety.refusal(for: svg(inner)) != nil, "refused: \(what)")
            }
            // Case must not be a way past it.
            T.expect(SVGSafety.refusal(for: svg("<SCRIPT>x()</SCRIPT>")) != nil,
                     "an uppercase script element")
            T.expect(SVGSafety.refusal(for: svg("<image HREF=\"HTTP://x/y\"/>")) != nil,
                     "an uppercase href and scheme")
        }

        T.suite("SVG safety: a namespace prefix is not a way past") {
            for prefixed in ["<svg:script>x()</svg:script>",
                             "<SVG:SCRIPT>x()</SVG:SCRIPT>",
                             "<s:foreignObject><p>x</p></s:foreignObject>",
                             "<html:iframe src=\"https://x/\"></html:iframe>"] {
                T.expect(SVGSafety.refusal(for: svg(prefixed)) != nil, "refused: \(prefixed.prefix(28))")
            }
            // A protocol-relative reference carries no scheme, so the scheme
            // tests miss it entirely while it still fetches.
            T.expect(SVGSafety.refusal(for: svg("<rect fill=\"url(//evil/x)\"/>")) != nil,
                     "a protocol-relative url()")
            T.expect(SVGSafety.refusal(for: svg("<image href=\"//evil/x.png\"/>")) != nil,
                     "a protocol-relative href")
            // And the words alone are still not enough to refuse a drawing.
            T.expect(SVGSafety.refusal(for: svg("<text>describe the script</text>")) == nil,
                     "the word script in text is not a script element")
            T.expect(SVGSafety.refusal(for: svg("<rect id=\"iframe-like\"/>")) == nil,
                     "nor an id that contains iframe")
        }

        T.suite("SVG safety: a harmless reference does not shield a hostile one") {
            // The check took the FIRST match and then asked whether that match
            // was a data: URI, so a data: reference placed in front of an
            // http: one short-circuited the whole test.
            let dataFirst = "<image href=\"data:image/png;base64,iVBOR\"/>"
                          + "<image href=\"http://127.0.0.1:1/x.png\"/>"
            T.expect(SVGSafety.refusal(for: svg(dataFirst)) != nil,
                     "data: before http: is still refused")
            let dataFirstURL = "<rect fill=\"url(data:image/png;base64,iVBOR)\"/>"
                             + "<rect fill=\"url(https://evil/x)\"/>"
            T.expect(SVGSafety.refusal(for: svg(dataFirstURL)) != nil,
                     "and in url() too")
            // Several data: references and nothing else must still pass.
            let onlyData = "<image href=\"data:image/png;base64,iVBOR\"/>"
                         + "<image href=\"data:image/png;base64,AAAA\"/>"
            T.expect(SVGSafety.refusal(for: svg(onlyData)) == nil, "data: only is kept")
        }

        T.suite("SVG safety: what a real diagram keeps") {
            let fine: [(String, String)] = [
                ("a plain rectangle", "<rect width=\"10\" height=\"10\" fill=\"blue\"/>"),
                ("a fragment use", "<defs><rect id=\"a\"/></defs><use href=\"#a\"/>"),
                ("a gradient by fragment", "<defs><linearGradient id=\"g\"/></defs><rect fill=\"url(#g)\"/>"),
                ("a data URI image", "<image href=\"data:image/png;base64,iVBORw0KGgo=\"/>"),
                ("a data URI in url()", "<rect fill=\"url(data:image/png;base64,iVBOR)\"/>"),
                ("a local stylesheet", "<style>.a{fill:red;stroke:#000}</style><rect class=\"a\"/>"),
                ("a relative reference", "<image href=\"pictures/x.png\"/>"),
                ("paths and text", "<path d=\"M0 0 L10 10\"/><text x=\"1\" y=\"2\">label</text>"),
                ("a clip path by fragment", "<rect clip-path=\"url(#c)\"/>"),
            ]
            for (what, inner) in fine {
                let why = SVGSafety.refusal(for: svg(inner))
                T.expect(why == nil, "kept: \(what)\(why.map { " — refused for \($0)" } ?? "")")
            }
        }

        T.suite("SVG safety: the message names the reason") {
            T.equal(SVGSafety.refusal(for: svg("<script>x()</script>")),
                    "it contains a script element", "a script says so")
            T.expect(SVGSafety.refusal(for: svg("<rect onload=\"x()\"/>"))?
                        .contains("event handler") == true, "a handler says so")
            // The scheme is no longer named: the check asks "is there a
            // reference whose scheme is not data:" in one pass, so there is
            // nothing left to inspect afterwards. Saying which one would mean
            // reintroducing the first-match inspection that was the bug.
            T.expect(SVGSafety.refusal(for: svg("<image href=\"http://x/y\"/>"))?
                        .contains("outside itself") == true, "a reference says so")
        }
    }
}
