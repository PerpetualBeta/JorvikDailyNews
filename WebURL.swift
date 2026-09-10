import Foundation

/// The one place that decides whether a URL taken from untrusted content may
/// be fetched or opened.
///
/// It exists because the rule was written six times and got it right five.
/// `EmbeddedArticle`, `ImageEnricher`, `FeedFetcher`, `AddFeedSheet` and
/// `OPMLImporter` each tested for http(s); the reader's own link path tested
/// only for `javascript:` and let everything else through, so any scheme
/// another installed app had registered reached `NSWorkspace.open` on one
/// click. A rule duplicated per call site is a rule that will be missed at the
/// next call site.
///
/// **An allow-list, not a deny-list.** A deny-list cannot enumerate the
/// schemes an arbitrary Mac has handlers for — `webcal:` subscribes Calendar
/// to an attacker's feed permanently, `smb:` prompts Finder for credentials
/// against an attacker's host, `ssh:` and `x-man-page:` hand a
/// command line to whatever terminal is installed, and `file:` will launch an
/// application at a fixed absolute path.
enum WebURL {

    /// Schemes an article, feed or page may name.
    ///
    /// Just the two. Every fetch the app makes is HTTP, and every link it
    /// opens is a web page. `mailto:` is deliberately absent: it is the one
    /// plausible addition, and it is also a header-injection surface into
    /// Mail.app, so it should arrive with a compose sheet rather than by
    /// widening this set.
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// Whether this URL may be fetched or handed to the system.
    ///
    /// Lowercased, because Foundation does not normalise it: `URL(string:
    /// "HTTP://example.com")?.scheme` is `"HTTP"`, so a bare `scheme == "http"`
    /// rejects a URL that is perfectly valid. Three of the five call sites this
    /// replaces had that bug. It failed closed, so it cost a working link
    /// rather than anything worse.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// A possibly-relative href from untrusted content, resolved and checked.
    ///
    /// Returns nil for anything that is not plainly a web address, so a caller
    /// that treats nil as "not a link" is safe by default.
    static func resolve(_ href: String?, against base: URL?) -> URL? {
        guard let href else { return nil }
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              isAllowed(resolved)
        else { return nil }
        return resolved
    }
}
