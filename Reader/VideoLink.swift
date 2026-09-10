import Foundation

/// A link that is a video rather than an article, and which player can take it.
///
/// This lived on `ReaderView` as `VideoTarget` plus a `detectVideo` static, and
/// `Feed.displayTitle` called it to append `[VIDEO]` to a title. That made a
/// model type depend on a SwiftUI view, which is backwards, and it had a cost
/// beyond tidiness: `FeedFetcher` could not be compiled without dragging in the
/// whole interface, so the most testable code in the app — pure functions from
/// bytes to items — had no tests and four faults that had been there since it
/// was written. Deciding whether a URL points at a video needs no view, so it
/// does not live in one.
///
/// The player *markup* stays in `ReaderSheet`: building an `<iframe>` host page
/// is a view's business. Only the classification moved.
enum VideoLink: Equatable {
    case youTube(String)   // video id
    case vimeo(String)     // video id
    case native(URL)

    /// File extensions `AVPlayer` will take directly.
    private static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov", "webm"]

    static func detect(_ url: URL) -> VideoLink? {
        let host = url.host?.lowercased() ?? ""

        if nativeExtensions.contains(url.pathExtension.lowercased()) {
            return .native(url)
        }
        if host.contains("youtube.com") || host == "youtu.be" || host.hasSuffix(".youtu.be") {
            if let id = youTubeID(url) { return .youTube(id) }
        }
        if host.contains("vimeo.com") {
            if let id = vimeoID(url) { return .vimeo(id) }
        }
        return nil
    }

    /// Characters a YouTube id may contain, and nothing else.
    ///
    /// The id is interpolated into an HTML attribute in
    /// `ReaderSheet.youTubeEmbedHTML`, so anything that can carry a quote or
    /// an angle bracket escapes the attribute. `URL.pathComponents` and
    /// `URLComponents.queryItems` both hand back **percent-decoded** text, so
    /// a feed item linking to
    ///
    ///     https://www.youtube.com/watch?v=a%22%3E%3Cimg%20src=x%20onerror=…%3E
    ///
    /// produced the id `a"><img src=x onerror=…>` and injected it into a
    /// JavaScript-enabled web view loaded with a base of
    /// `https://jorviksoftware.cc`, so the injected script ran with the
    /// project's own origin.
    ///
    /// Escaping at the point of interpolation would fix that one site.
    /// Validating here fixes it for every site, present and future, and a real
    /// id has no business containing anything outside this set.
    private static let youTubeIDCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// Eleven is the standard length. The bound is loose because YouTube has
    /// changed id formats before and a longer real id should not stop a video
    /// playing; it is here only so an unbounded string cannot be carried
    /// around.
    private static let maxVideoIDLength = 64

    private static func validYouTubeID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= maxVideoIDLength,
              raw.allSatisfy({ youTubeIDCharacters.contains($0) })
        else { return nil }
        return raw
    }

    /// Vimeo ids are decimal, and the same reasoning applies.
    private static func validVimeoID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= maxVideoIDLength,
              raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber)
        else { return nil }
        return raw
    }

    private static func youTubeID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("youtu.be") { return validYouTubeID(parts.first) }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return validYouTubeID(v)
        }
        // /embed/ID, /shorts/ID, /v/ID
        if let idx = parts.firstIndex(where: { ["embed", "shorts", "v"].contains($0) }),
           idx + 1 < parts.count {
            return validYouTubeID(parts[idx + 1])
        }
        return nil
    }

    private static func vimeoID(_ url: URL) -> String? {
        // vimeo.com/123456789 or player.vimeo.com/video/123456789
        let parts = url.pathComponents.filter { $0 != "/" }
        // `Character.isNumber` is true for Arabic-Indic and other non-ASCII
        // digits, which cannot carry a quote but can build a nonsense URL.
        return parts.compactMap(validVimeoID).last
    }
}
