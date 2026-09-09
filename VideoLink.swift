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

    private static func youTubeID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("youtu.be") { return parts.first }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        // /embed/ID, /shorts/ID, /v/ID
        if let idx = parts.firstIndex(where: { ["embed", "shorts", "v"].contains($0) }),
           idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }

    private static func vimeoID(_ url: URL) -> String? {
        // vimeo.com/123456789 or player.vimeo.com/video/123456789
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.last(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }
}
