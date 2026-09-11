import AppKit
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

    /// **What this does not stop.** A public hostname whose DNS resolves to a
    /// private address goes straight through, because the check is on the URL
    /// and not on the socket. Closing that means resolving the name before
    /// connecting and rejecting on the answer, which adds a lookup to every
    /// fetch and is still a race — the address can change between the check
    /// and the connection. It is worth doing and it is not this change.
    ///
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
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme)
        else { return false }
        return !isPrivateHost(url)
    }

    // MARK: - Where the request may go

    /// Whether this address is somewhere on the machine or the local network
    /// rather than out on the internet.
    ///
    /// Nothing in the app has any business fetching one. Every feed is a
    /// public host, and a URL naming a private address came from content
    /// rather than from the user: `<img src="http://127.0.0.1:7703/kb/export">`
    /// in a feed description is fetched with no click at all, and a frame
    /// pointing at `http://169.254.169.254/latest/meta-data/` has its response
    /// **rendered back to the reader**, which turns a blind fetch into a read.
    ///
    /// The router at `192.168.1.1`, a debug server on `localhost:8080`, an
    /// unauthenticated Elasticsearch on `127.0.0.1:9200`, a `.local` printer:
    /// all of them answer requests from this machine that they would never
    /// answer from outside it, which is exactly what makes the app a useful
    /// proxy for someone who cannot reach them.
    /// Hands a URL to the browser, or refuses it.
    ///
    /// One funnel, because three call sites in `ReaderSheet` opened a feed's
    /// own link directly — the toolbar button present in every reader state,
    /// and two notice buttons, one of them carrying the default keyboard
    /// action. `NativeReaderView.open` had always applied the rule to links
    /// *inside* an article; the item's own link was the one that skipped it.
    ///
    /// Refusing rather than asking: a link the app would not fetch is not a
    /// link worth handing to another application either.
    @discardableResult
    static func openInBrowser(_ url: URL) -> Bool {
        guard isAllowed(url) else {
            jdnLog("open: refused \(url.scheme ?? "(no scheme)"): — not a public web address")
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    static func isPrivateHost(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return true }
        // A URL literal wraps IPv6 in brackets.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // **The DNS root label. One character, and it defeated everything.**
        // `127.0.0.1.` is a legal, fully-qualified spelling of loopback that
        // resolvers accept — and it parses as neither an address nor a name, so
        // `ipv4Readings` returned nothing and `isPrivateName` matched nothing,
        // and the host was allowed. Verified: 127.0.0.1., 192.168.1.1.,
        // 10.0.0.5. and 169.254.169.254. were all permitted.
        //
        // Every guard in this app delegates here — the redirect guard,
        // BoundedFetch, the video pre-flight, the PDF download, the live page —
        // so this was the single point where all of them failed together.
        //
        // Stripped in a loop, because `127.0.0.1..` is the same trick twice.
        while host.hasSuffix(".") { host = String(host.dropLast()) }
        guard !host.isEmpty else { return true }
        // Every reading of the host, and private if ANY of them is. One
        // spelling can mean two addresses, and the safe answer is to refuse
        // when either is somewhere it should not go.
        let readings = ipv4Readings(host)
        if !readings.isEmpty { return readings.contains(where: isPrivate) }
        if let v6 = ipv6(host) { return isPrivate(v6) }
        return isPrivateName(host)
    }

    // MARK: IPv4

    /// Every address this host string could mean, as an IPv4 address.
    ///
    /// Both readings, not the first that parses, because the two parsers
    /// disagree and the disagreement is exploitable. `0177.0.0.1`:
    ///
    ///     inet_pton -> 177.0.0.1   (reads 0177 as decimal 177, and SUCCEEDS)
    ///     inet_aton -> 127.0.0.1   (reads 0177 as octal, which is what a
    ///                               browser does)
    ///
    /// Taking the strict answer and stopping therefore judged a *public*
    /// address and let the request through to loopback. `inet_aton` also
    /// accepts `0x7f.0.0.1`, `127.1` and `2130706433`, all of which are
    /// 127.0.0.1 and none of which `inet_pton` parses at all.
    ///
    /// So both are asked and the caller refuses if either lands somewhere
    /// private. A host that is genuinely public reads the same both ways.
    private static func ipv4Readings(_ host: String) -> [UInt32] {
        var found: [UInt32] = []
        var strict = in_addr()
        if inet_pton(AF_INET, host, &strict) == 1 { found.append(strict.s_addr.bigEndian) }
        var legacy = in_addr()
        if inet_aton(host, &legacy) == 1 {
            let value = legacy.s_addr.bigEndian
            if !found.contains(value) { found.append(value) }
        }
        return found
    }

    private static func isPrivate(_ address: UInt32) -> Bool {
        func inRange(_ prefix: UInt32, _ bits: UInt32) -> Bool {
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            return (address & mask) == (prefix & mask)
        }
        return inRange(0x00000000, 8)      // 0.0.0.0/8, "this network"
            || inRange(0x7F000000, 8)      // 127.0.0.0/8, loopback
            || inRange(0x0A000000, 8)      // 10.0.0.0/8
            || inRange(0xAC100000, 12)     // 172.16.0.0/12
            || inRange(0xC0A80000, 16)     // 192.168.0.0/16
            || inRange(0xA9FE0000, 16)     // 169.254.0.0/16, link-local + cloud metadata
            || inRange(0x64400000, 10)     // 100.64.0.0/10, carrier NAT
            || inRange(0xC0000000, 24)     // 192.0.0.0/24, IETF protocol assignments
            || inRange(0xE0000000, 4)      // 224.0.0.0/4, multicast
            || inRange(0xF0000000, 4)      // 240.0.0.0/4, reserved + broadcast
    }

    // MARK: IPv6

    private static func ipv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func isPrivate(_ address: [UInt8]) -> Bool {
        guard address.count == 16 else { return true }
        // ::1 loopback, and :: unspecified.
        if address.dropLast().allSatisfy({ $0 == 0 }) { return true }
        // fe80::/10 link-local, and fec0::/10 site-local.
        if address[0] == 0xFE, (address[1] & 0xC0) == 0x80 || (address[1] & 0xC0) == 0xC0 { return true }
        // fc00::/7 unique local.
        if (address[0] & 0xFE) == 0xFC { return true }
        // ::ffff:a.b.c.d — an IPv4 address wearing an IPv6 hat, so it has to
        // be judged by the IPv4 rules or every block above is bypassed.
        let v4Mapped = address[0..<10].allSatisfy { $0 == 0 }
            && address[10] == 0xFF && address[11] == 0xFF
        if v4Mapped {
            let packed = (UInt32(address[12]) << 24) | (UInt32(address[13]) << 16)
                       | (UInt32(address[14]) << 8) | UInt32(address[15])
            return isPrivate(packed)
        }
        return false
    }

    // MARK: Names

    /// Names that only mean something on this machine or this network.
    ///
    /// A single-label host is included deliberately: `http://intranet/` has no
    /// dot, resolves through the machine's search domains, and is a plain
    /// route to an internal service. Nothing on the public internet is
    /// reachable without a dot.
    private static func isPrivateName(_ host: String) -> Bool {
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        if bare.isEmpty { return true }
        if bare == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".intranet",
                       ".home.arpa", ".lan", ".corp", ".private"] {
            if bare.hasSuffix(suffix) { return true }
        }
        return !bare.contains(".")
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
