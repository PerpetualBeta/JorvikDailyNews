import Foundation

/// A last look at an SVG before `NSImage(data:)` is handed it.
///
/// The walker sanitises at capture time, which is where the DOM is and so where
/// the job is done properly. This is the second check, for the same reason
/// `InlineSVG` re-checks the size ceiling: the two are separate components, one
/// JavaScript in a bundled resource and one Swift, and a rule enforced in only
/// one of them is one edit away from being gone. A security boundary worth
/// having is worth holding in both halves.
///
/// **It is not about stored blocks.** An earlier version of this said editions
/// on disk carry raw SVG. They do not — checked 2026-09-11, an edition stores
/// feed items only and holds no blocks — so the second check earns its place on
/// defence in depth alone, which is a weaker argument than the one first given
/// and still a sufficient one.
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
