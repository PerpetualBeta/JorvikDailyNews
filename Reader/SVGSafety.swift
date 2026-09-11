import Foundation

/// A last look at an SVG before `NSImage(data:)` is handed it.
///
/// The walker sanitises at capture time, which is where the DOM is and so where
/// the job is done properly. This is the far side of a stored boundary: an
/// edition written before that existed still holds raw source, and the app
/// reads yesterday's editions every day. `InlineSVG` re-checks the size ceiling
/// for exactly the same reason.
///
/// **It refuses rather than repairs.** Repairing needs a parser, and reaching
/// for one here would put a second XML parser in the app to defend against the
/// first. What reaches this point and still looks dangerous came from an old
/// edition, so refusing costs one diagram in one day's paper.
///
/// Foundation only, no DOM, so the suite can exercise it directly.
enum SVGSafety {

    /// Why an SVG will not be drawn, or nil when it is fine.
    static func refusal(for source: String) -> String? {
        let s = source.lowercased()

        if s.contains("<script") { return "it contains a script element" }
        if s.contains("<foreignobject") { return "it contains a foreignObject" }
        if s.contains("<iframe") { return "it contains an iframe" }
        if s.contains("@import") { return "its stylesheet imports another" }

        // An event handler: `onload=`, `onclick=`, `onbegin=`, with any amount
        // of space around the equals sign.
        if s.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) != nil {
            return "it carries an event handler"
        }

        // Any reference with a scheme other than data:. Fragment references
        // (`#id`) and relative ones have no scheme and so do not match, which
        // is deliberate: `<use href="#icon">` is how real diagrams are built.
        if let range = s.range(of: #"(href|src)\s*=\s*['"]?\s*([a-z][a-z0-9+.-]*:)"#,
                               options: .regularExpression) {
            let scheme = String(s[range])
            if !scheme.contains("data:") { return "it references \(trimScheme(scheme))" }
        }
        if let range = s.range(of: #"url\(\s*['"]?\s*([a-z][a-z0-9+.-]*:)"#,
                               options: .regularExpression) {
            let scheme = String(s[range])
            if !scheme.contains("data:") { return "a url() references \(trimScheme(scheme))" }
        }
        return nil
    }

    /// The scheme on its own, for the log line. Best-effort: the message is for
    /// a human reading a log, so a miss costs nothing.
    private static func trimScheme(_ match: String) -> String {
        guard let colon = match.lastIndex(of: ":") else { return "something outside itself" }
        let start = match[..<colon].lastIndex(where: { !$0.isLetter && !$0.isNumber })
            .map { match.index(after: $0) } ?? match.startIndex
        return String(match[start...colon])
    }
}
