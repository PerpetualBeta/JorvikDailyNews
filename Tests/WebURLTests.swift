import Foundation

/// One predicate decides where every fetch may go and what every article link
/// may open. Its job is to be boringly strict, so most of this is a list of
/// things that must be refused.
enum WebURLTests {

    private static func allowed(_ s: String) -> Bool {
        guard let url = URL(string: s) else { return false }
        return WebURL.isAllowed(url)
    }

    static func run() {
        T.suite("WebURL: a trailing dot is not a way past the policy") {
            // The DNS root label. One character, legal, and resolvers accept
            // it — and it parsed as neither an address nor a name, so every
            // private range was permitted. Every guard in the app delegates
            // here, so this was the single point where all of them failed.
            for host in ["127.0.0.1.", "127.0.0.1..", "localhost.", "192.168.1.1.",
                         "10.0.0.5.", "172.16.4.4.", "169.254.169.254.",
                         "router.local.", "0177.0.0.1.", "2130706433."] {
                T.expect(!allowed("http://\(host)/x"), "refused: \(host)")
            }
            // An ordinary fully-qualified name is still fine.
            T.expect(allowed("https://example.com./x"), "a public name with a root label")
            T.expect(allowed("https://arstechnica.com/x"), "and without one")
        }

        T.suite("WebURL: the public internet is allowed") {
            for s in ["https://example.com/a", "http://example.com/a",
                      "HTTPS://Example.COM/a", "https://sub.example.co.uk/x?y=1#z",
                      "https://8.8.8.8/", "https://[2001:4860:4860::8888]/"] {
                T.expect(allowed(s), "allows \(s)")
            }
        }

        T.suite("WebURL: schemes other than http(s)") {
            for s in ["file:///etc/passwd", "FILE:///etc/passwd", "javascript:alert(1)",
                      "data:text/html,<script>", "webcal://a.example/x", "smb://a.example/s",
                      "ssh://a.example", "mailto:a@b.example", "about:blank",
                      "ftp://a.example/f"] {
                T.expect(!allowed(s), "refuses \(s)")
            }
        }

        T.suite("WebURL: loopback and this machine") {
            for s in ["http://127.0.0.1/", "http://127.0.0.1:9200/_cluster/health",
                      "http://127.1.2.3/", "http://localhost/", "http://localhost:8080/x",
                      "http://LOCALHOST/", "http://foo.localhost/", "http://[::1]/",
                      "http://0.0.0.0/", "http://[::]/"] {
                T.expect(!allowed(s), "refuses \(s)")
            }
        }

        T.suite("WebURL: the local network") {
            for s in ["http://10.0.0.1/", "http://10.255.255.254/",
                      "http://172.16.0.1/", "http://172.31.255.254/",
                      "http://192.168.1.1/", "http://192.168.0.254/",
                      "http://100.64.0.1/",
                      "http://printer.local/", "http://intranet/",
                      "http://wiki.internal/", "http://db.lan/"] {
                T.expect(!allowed(s), "refuses \(s)")
            }
            // The addresses either side of a private block must still work, or
            // the mask arithmetic is wrong and legitimate hosts are lost.
            for s in ["http://9.255.255.255/", "http://11.0.0.1/",
                      "http://172.15.255.255/", "http://172.32.0.1/",
                      "http://192.167.255.255/", "http://192.169.0.1/"] {
                T.expect(allowed(s), "still allows \(s), just outside a private range")
            }
        }

        T.suite("WebURL: cloud metadata") {
            // 169.254.169.254 is the address that turns an SSRF into
            // credentials on every major cloud.
            T.expect(!allowed("http://169.254.169.254/latest/meta-data/"), "AWS/GCP metadata")
            T.expect(!allowed("http://169.254.0.1/"), "the rest of link-local with it")
            T.expect(!allowed("http://[fe80::1]/"), "and the IPv6 form")
        }

        T.suite("WebURL: the legacy IPv4 spellings") {
            // All of these are 127.0.0.1 and a browser connects to every one.
            // `inet_pton` accepts none of them, so a strict-only check leaves
            // them as a way straight past the block.
            for s in ["http://2130706433/", "http://0x7f.0.0.1/", "http://0177.0.0.1/",
                      "http://127.1/", "http://0x7f000001/"] {
                T.expect(!allowed(s), "refuses \(s), which is 127.0.0.1")
            }
        }

        T.suite("WebURL: IPv4 wearing an IPv6 hat") {
            for s in ["http://[::ffff:127.0.0.1]/", "http://[::ffff:10.0.0.1]/",
                      "http://[::ffff:169.254.169.254]/"] {
                T.expect(!allowed(s), "refuses \(s)")
            }
            T.expect(allowed("http://[::ffff:8.8.8.8]/"), "but a public one still works")
        }

        T.suite("WebURL: unique-local and site-local IPv6") {
            for s in ["http://[fc00::1]/", "http://[fd12:3456::1]/", "http://[fec0::1]/"] {
                T.expect(!allowed(s), "refuses \(s)")
            }
        }

        T.suite("WebURL: nothing to judge") {
            T.expect(!allowed("https://"), "no host")
            T.expect(WebURL.resolve(nil, against: nil) == nil, "no href")
            T.expect(WebURL.resolve("   ", against: nil) == nil, "whitespace")
            T.expect(WebURL.resolve("/relative", against: nil) == nil,
                     "relative with no base cannot resolve")
        }

        T.suite("WebURL: resolution keeps the check") {
            let base = URL(string: "https://example.com/news/story")!
            T.equal(WebURL.resolve("/other", against: base)?.absoluteString,
                    "https://example.com/other", "a relative href resolves")
            // A page cannot escape the rule by writing its link relatively.
            T.expect(WebURL.resolve("//127.0.0.1/x", against: base) == nil,
                     "protocol-relative to loopback is still refused")
        }
    }
}
