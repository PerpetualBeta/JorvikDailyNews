import Foundation

/// A `mailto:` link from an article, taken apart so the reader can be shown
/// what it would actually do.
///
/// `mailto:` is the one non-web scheme worth keeping: an author's byline
/// address, a corrections desk, a tip line. It is also the one that carries
/// fields the reader cannot see. `mailto:desk@paper.example?bcc=harvest@
/// attacker.example&subject=…&body=…` opens a message addressed somewhere the
/// composer's own window may not show prominently, and a feed chooses every
/// character of it.
///
/// So it never reaches `NSWorkspace.open` as written. It is parsed here, shown
/// in a sheet, and rebuilt from only the parts the reader was shown.
struct MailtoLink: Equatable, Identifiable {

    /// Identity is the link itself, so presenting the same address twice does
    /// not confuse SwiftUI's sheet.
    var id: String { original.absoluteString }


    /// Addresses in the `to` position, after the scheme.
    let to: [String]
    /// The `subject` field, if any, with control characters removed.
    let subject: String?
    /// The link exactly as the article wrote it.
    ///
    /// Kept because the *sheet* must be able to say what it is dropping, and
    /// `safeURL` has already dropped it. Setting the rendered link attribute
    /// to `safeURL` meant `open(_:)` re-parsed a URL with the `bcc` already
    /// gone, so the sheet reported nothing removed — which is the one thing it
    /// exists to report.
    let original: URL
    /// Fields that exist in the link and are deliberately NOT passed on:
    /// `cc`, `bcc`, `body`, and anything else. Named so the sheet can say what
    /// it is dropping rather than dropping it silently.
    let discarded: [String]

    // MARK: - Parsing

    /// Whether this URL is a mailto at all.
    static func isMailto(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "mailto"
    }

    /// Take a mailto apart, or return nil if there is no address in it.
    init?(_ url: URL) {
        guard Self.isMailto(url) else { return nil }
        // `URLComponents` puts everything after `mailto:` in `path`, and any
        // `?…` in `query`.
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        original = url

        let addresses = parts.path
            .split(separator: ",")
            .map { Self.clean(String($0).removingPercentEncoding ?? String($0)) }
            .filter { Self.looksLikeAnAddress($0) }
        guard !addresses.isEmpty else { return nil }
        to = addresses

        var foundSubject: String?
        var dropped: [String] = []
        for item in parts.queryItems ?? [] {
            let name = item.name.lowercased()
            if name == "subject", let value = item.value, !value.isEmpty {
                foundSubject = Self.clean(value)
            } else if !item.name.isEmpty {
                dropped.append(name)
            }
        }
        subject = foundSubject
        discarded = dropped
    }

    /// Strips the characters that turn one header into two.
    ///
    /// A newline or carriage return in a subject is header injection in the
    /// composer: everything after it can present as a new field. Control
    /// characters go the same way, since none of them belong in a subject and
    /// several are invisible.
    private static func clean(_ s: String) -> String {
        String(s.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7F
              || scalar.properties.generalCategory == .control
              || scalar.properties.generalCategory == .format)
        }.map(Character.init))
        .trimmingCharacters(in: .whitespaces)
    }

    /// A deliberately plain test. It is not here to validate RFC 5322 — Mail
    /// will do that — but to stop something that is not an address at all
    /// being presented to the reader as one.
    private static func looksLikeAnAddress(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 254, !s.contains(" ") else { return false }
        let halves = s.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return false }
        return !halves[0].isEmpty && halves[1].contains(".") && !halves[1].hasPrefix(".")
    }

    // MARK: - Handing it on

    /// What the reader sees in the sheet.
    var recipients: String { to.joined(separator: ", ") }

    /// A mailto rebuilt from only what the sheet displayed.
    ///
    /// Rebuilt rather than forwarded, so nothing the reader was not shown can
    /// ride along. Percent-encoded from the parsed values, so a subject
    /// containing `&` or `?` cannot introduce another field.
    var safeURL: URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = to.joined(separator: ",")
        if let subject, !subject.isEmpty {
            parts.queryItems = [URLQueryItem(name: "subject", value: subject)]
        }
        return parts.url
    }
}
