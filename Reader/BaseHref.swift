import Foundation

/// Putting a `<base href>` on a document the reader fetched itself.
///
/// Rungs 3 and 4 of the extraction ladder load the article from a private
/// scheme or from a temporary file, so `document.baseURI` is no longer the
/// article's own address, and Readability's `_fixRelativeUris` reads exactly
/// that property when it makes links and images absolute.
///
/// Its own file, with no dependencies, so the rule it enforces can be tested
/// without standing up an extractor, a web view and a JavaScript context.
enum BaseHref {

    /// Put a `<base href>` at the top of the document's head.
    ///
    /// **Going first in the head was not enough, twice over.**
    ///
    /// The comment here used to say that the first `<base href>` in document
    /// order is the one the parser honours, so a page shipping its own base
    /// tag could not override ours. Both halves of that were wrong.
    ///
    /// The insertion is textual — `range(of: "<head")`, then `"<html"` — with
    /// no awareness of comments, CDATA or attribute values, so a page opening
    /// with the literal string `<head` inside a comment swallows the injected
    /// tag entirely.
    ///
    /// And independently of where the injection lands, the spec's "before
    /// head" insertion mode treats a `<base>` start tag as "anything else": it
    /// opens an implied `<head>`, puts the base in it, and a later explicit
    /// `<head>` token is a parse error and ignored. So a page declaring its
    /// own base before its head is first in tree order whatever we do.
    ///
    /// The only way to honour the claim is to remove the page's base tags,
    /// which is what happens now.
    ///
    /// Reachable from rung 4 (`.fileURL`), which passes raw fetched HTML. The
    /// cost there was correctness rather than a fetch — relative links and
    /// images resolving against the staging directory or the page's chosen
    /// host — because a WebKit rung emits no blocks, so the article is drawn
    /// by `ReaderWebView` with `baseURL: item.link` and the subresource rule
    /// list attached. The other call site passes this app's own template.
    static func apply(to html: String, base url: URL) -> String {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let tag = "<base href=\"\(escaped)\">"
        let document = stripped(html)
        // After `<head>` if there is one, otherwise after `<html>`, otherwise
        // at the very front. Never before the doctype, which would drop the
        // parser into quirks mode and change the DOM we are trying to read.
        for opener in ["<head", "<html"] {
            guard let start = document.range(of: opener, options: .caseInsensitive) else { continue }
            guard let close = document.range(of: ">", range: start.upperBound..<document.endIndex)
            else { continue }
            var out = document
            out.insert(contentsOf: tag, at: close.upperBound)
            return out
        }
        return tag + document
    }

    /// Every `<base …>` the document declares for itself, removed.
    ///
    /// A linear scan rather than a pattern. `<base\b[^>]*>` looks obvious and
    /// is quadratic on `<base<base<base…`: every start position rescans to the
    /// end looking for a `>` that is not there. The index here always advances
    /// past what it has read.
    ///
    /// It is textual, so a literal `<base ` inside a script or a comment goes
    /// too. Scripts do not run on the rung that reaches this, and Readability
    /// reads structure, so the cost of that is nothing; the cost of leaving a
    /// page's own base in place is every relative link resolving somewhere
    /// else.
    static func stripped(_ html: String) -> String {
        guard html.range(of: "<base", options: .caseInsensitive) != nil else { return html }
        var out = ""
        out.reserveCapacity(html.count)
        var index = html.startIndex
        while let start = html.range(of: "<base", options: .caseInsensitive,
                                     range: index..<html.endIndex) {
            // `<basefont>` is a different element, and `<baseball>` is not one
            // at all. The name has to end here.
            if start.upperBound < html.endIndex {
                let after = html[start.upperBound]
                if after.isLetter || after.isNumber || after == "-" {
                    out += html[index..<start.upperBound]
                    index = start.upperBound
                    continue
                }
            }
            out += html[index..<start.lowerBound]
            guard let gt = html.range(of: ">", range: start.upperBound..<html.endIndex) else {
                // No `>` anywhere after it: the rest of the document is inside
                // this tag, and a parser would lose it too.
                return out
            }
            index = gt.upperBound
        }
        out += html[index...]
        return out
    }
}
