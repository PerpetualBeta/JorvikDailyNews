import Foundation

/// Links in a rendered article looked like links and did nothing when clicked,
/// for as long as the native reader has existed. The rendering half of that is
/// not testable without a screen; where a link *points* is, and it is the half
/// that fails silently — a wrong resolution opens the wrong page rather than
/// no page, and nobody reports it as a bug.
enum ReaderLinkTests {

    private static let base = URL(string: "https://example.com/news/2026/story")!

    static func run() {
        T.suite("Links: absolute addresses pass through") {
            equal("https://other.example/thing", "https://other.example/thing", "https")
            equal("http://other.example/thing", "http://other.example/thing", "http")
            // Foundation does not normalise the scheme's case, so the check
            // has to. `URL(string: "HTTP://x")?.scheme` is "HTTP".
            equal("HTTPS://other.example/thing", "HTTPS://other.example/thing", "uppercase scheme")
        }

        T.suite("Links: only the web, and nothing else") {
            // Every one of these had a handler on the machine this was written
            // on, and each reached NSWorkspace.open on a single click with no
            // consent step: webcal subscribes Calendar to the attacker's feed
            // permanently, smb prompts Finder for credentials against their
            // host, ssh and x-man-page hand a command line to a terminal, and
            // file:// launches an application at a fixed absolute path.
            for scheme in ["file:///System/Applications/Utilities/Terminal.app",
                           "webcal://attacker.example/track.ics",
                           "smb://attacker.example/share",
                           "afp://attacker.example/share",
                           "vnc://attacker.example:5900",
                           "ssh://root@attacker.example",
                           "telnet://attacker.example",
                           "x-man-page://ls",
                           "itms://attacker.example",
                           "macappstore://apps.apple.com/app/id1",
                           "vscode://file//Users/x/.ssh/id_rsa:1:1",
                           "mailto:someone@example.com",
                           "tel:+441234567890",
                           "data:text/html,<script>alert(1)</script>",
                           "about:blank"] {
                T.expect(run(scheme) == nil, "refuses \(scheme.prefix(28))")
            }
            // And the case-shifted forms, since a deny-list would have been
            // beaten by these even if it had listed the schemes above.
            T.expect(run("FILE:///etc/passwd") == nil, "refuses an uppercase file scheme")
            T.expect(run("JavaScript:alert(1)") == nil, "still refuses javascript")
        }

        T.suite("Links: relative addresses resolve against the article") {
            // The common case. A feed that hands us /news/story is not giving
            // us a broken link, it is giving us a relative one.
            equal("/other", "https://example.com/other", "root relative")
            equal("sibling", "https://example.com/news/2026/sibling", "path relative")
            equal("../up", "https://example.com/news/up", "one level up")
            equal("//cdn.example/x.html", "https://cdn.example/x.html", "protocol relative")
        }

        T.suite("Links: a bare fragment goes to the article's own page") {
            // There are no anchors in the rendered blocks to jump to, so the
            // honest answer is the real page at that spot.
            equal("#footnote-3", "https://example.com/news/2026/story#footnote-3", "fragment")
        }

        T.suite("Links: what must lead nowhere") {
            // A run with no href is ordinary prose.
            T.expect(run(nil) == nil, "no href")
            T.expect(run("") == nil, "empty href")
            T.expect(run("   ") == nil, "whitespace only")
            // `javascript:` cannot do anything here, and opening a browser to
            // show its source would be worse than ignoring it.
            T.expect(run("javascript:void(0)") == nil, "javascript scheme")
            T.expect(run("JavaScript:alert(1)") == nil, "and case does not save it")
        }

        T.suite("Links: the base is the page's own address, not the feed's") {
            // A feed link that redirects gives a base whose host and path are
            // not the article's. Resolving against it sends every relative
            // link in the prose to the wrong site.
            let feedLink = URL(string: "https://feeds.feedburner.com/example/abc123")!
            let real = URL(string: "https://example.com/news/2026/story")!
            let run = ReaderBlock.Run(text: "more", bold: false, italic: false,
                                      code: false, href: "/archive")
            T.equal(run.destination(relativeTo: feedLink)?.absoluteString,
                    "https://feeds.feedburner.com/archive",
                    "against the feed's link this goes to FeedBurner")
            T.equal(run.destination(relativeTo: real)?.absoluteString,
                    "https://example.com/archive",
                    "against the resolved address it goes to the site")
        }

        T.suite("Links: surrounding whitespace is not a broken link") {
            // Feeds ship href="\n  /story  \n" more often than one would hope.
            equal("  /other\n", "https://example.com/other", "trimmed before resolving")
        }
    }

    // MARK: - Helpers

    private static func run(_ href: String?) -> URL? {
        ReaderBlock.Run(text: "link", bold: false, italic: false, code: false, href: href)
            .destination(relativeTo: base)
    }

    private static func equal(_ href: String, _ want: String, _ what: String,
                              file: String = #fileID, line: Int = #line) {
        T.equal(run(href)?.absoluteString, want, what, file: file, line: line)
    }
}
