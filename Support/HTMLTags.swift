import Foundation

/// Pulling tags out of markup without letting a pattern walk the document.
///
/// **`<tag\b[^>]*>` over a whole body is quadratic, and this project has now
/// been bitten by that shape five times.** With no `>` anywhere after the
/// opener, ICU matches the name, walks the character class to end of input,
/// and backtracks a character at a time — from every one of the millions of
/// positions the opener appears at. Measured on the shipped code, all of them
/// a clean 4x per doubling:
///
/// - `FeedDiscovery.parseLinkTags`: 1.75 s at 32 KB, 27.9 s at 128 KB, and
///   256 KB did not finish inside 120 s — against a body it buffers to 32 MB.
/// - `EmbeddedArticle.frames`: 11.16 s at 128 KB, 201.8 s at 512 KB, on the
///   main actor, where the reader's own 25 s backstop cannot run because it is
///   a `Task { @MainActor }` and the actor is inside the regex.
/// - `Standfirst.flatten`: 11.0 s at 32 KB, 44.8 s at 64 KB, per item, sixteen
///   feeds at a time.
///
/// Bounding the character class is not enough: `<[^>]{1,512}>` still measured
/// 1.793 s on the same 64 KB body. The scan has to stop looking.
///
/// So this finds each opener, looks ahead a bounded distance for the `>` that
/// would close it, and **skips the whole window when there is none** — because
/// nothing starting inside that window can be a tag either. Advancing by one
/// instead is what made it quadratic in the first place, and would put the
/// same fault in the splitter rather than the pattern.
///
/// `NSRegularExpression` never polls `Task.isCancelled` and `work.cancel()`
/// does nothing to a running match, so none of these were recoverable once
/// started: the 300 s refresh watchdog abandons the refresh and leaves the
/// thread spinning for the life of the process.
enum HTMLTags {

    /// Longest a single tag may be before it is treated as malformed. A real
    /// `<meta>`, `<link>` or `<iframe>` is well under this; the attack has no
    /// `>` at all.
    static let maxTag = 4096

    /// Most tags of one name that will be returned from one document.
    static let maxTags = 512

    /// Every `<name …>` in `html`, each as its own short string.
    ///
    /// The result is what a per-tag pattern should be run against. Matching
    /// `[^>]*` inside a 4 KB string is bounded by construction, which is the
    /// whole point.
    static func named(_ name: String, in html: String, limit: Int = maxTags) -> [String] {
        var out: [String] = []
        var index = html.startIndex
        let opener = "<" + name
        while let start = html.range(of: opener, options: [.caseInsensitive],
                                     range: index..<html.endIndex) {
            let window = html.index(start.lowerBound, offsetBy: maxTag,
                                    limitedBy: html.endIndex) ?? html.endIndex
            if let close = html.range(of: ">", range: start.upperBound..<window) {
                out.append(String(html[start.lowerBound...close.lowerBound]))
                index = close.upperBound
            } else {
                index = window
                if window == html.endIndex { break }
            }
            if out.count >= limit { break }
        }
        return out
    }
}
