import Foundation

/// The rule applied to every hop of a redirect chain.
///
/// Before this existed, `WebURL.isAllowed` was tested on the URL the app asked
/// for and `URLSession` followed up to 20 hops on its own with nothing testing
/// where it ended up. Proved against a local server: unguarded, a public-looking
/// start URL answering `302 Location: http://127.0.0.1/secret` returned the
/// loopback body; guarded, the chain stops at the 302.
enum RedirectGuardTests {

    private static func permits(_ s: String) -> Bool {
        RedirectGuard.permits(URL(string: s))
    }

    static func run() {
        T.suite("Redirect guard: a hop to somewhere private is refused") {
            for target in ["http://127.0.0.1:9200/_search",
                           "http://localhost/admin",
                           "http://192.168.1.1/",
                           "http://10.0.0.5/",
                           "http://172.16.4.4/",
                           "http://169.254.169.254/latest/meta-data/",
                           "http://[::1]/",
                           "http://[fd00::1]/",
                           "http://router.local/"] {
                T.expect(!permits(target), "refused: \(target)")
            }
            // The alternate spellings WebURL already knows about, restated here
            // because a redirect is exactly where an attacker would reach for
            // one.
            for target in ["http://0177.0.0.1/", "http://2130706433/", "http://0x7f.1/"] {
                T.expect(!permits(target), "refused an alternate spelling: \(target)")
            }
        }

        T.suite("Redirect guard: an ordinary hop is allowed") {
            for target in ["https://arstechnica.com/a",
                           "http://example.com/b",
                           "https://cdn.example.co.uk/pic.jpg?w=800"] {
                T.expect(permits(target), "allowed: \(target)")
            }
        }

        T.suite("Redirect guard: anything that is not a web address is refused") {
            for target in ["file:///etc/passwd", "ftp://example.com/x",
                           "javascript:alert(1)", "data:text/html,x"] {
                T.expect(!permits(target), "refused: \(target)")
            }
            T.expect(!RedirectGuard.permits(nil), "a hop with no URL at all")
        }
    }
}
