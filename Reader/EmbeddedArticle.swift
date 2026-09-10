import Foundation

/// Finds the article a wrapper page is standing in front of.
///
/// Some pages are a frame around somebody else's document and carry almost no
/// text of their own. A Hugging Face Space is the case that prompted this:
/// `huggingface.co/spaces/HuggingEnvs/geoguesser-article` is 28,153 characters
/// of site chrome holding **50 characters** Readability would call an article,
/// while the piece itself — 62,795 characters, 173 paragraphs, 35 headings —
/// sits in an iframe at `huggingenvs-geoguesser-article.hf.space`.
///
/// This is only ever consulted after extraction has already failed, which is
/// the safeguard that matters. A real article that happens to embed a video or
/// a map is never touched, because its own text satisfied the reader long
/// before anything here was asked.
enum EmbeddedArticle {

    /// The frame worth following, or nil.
    static func candidate(in html: String, base: URL) -> URL? {
        for match in frames(in: html) {
            guard let src = attribute("src", in: match),
                  let url = WebURL.resolve(src, against: base)
            else { continue }
            if isDecoration(url) { continue }
            if isTiny(match) { continue }
            return url
        }
        return nil
    }

    /// Frames that are never the article.
    ///
    /// Players, embeds and trackers. Following one of these would replace a
    /// page that merely failed to parse with somebody's advertising, which is
    /// a far worse outcome than the honest "no article here" the reader shows
    /// today.
    ///
    /// Videos are excluded for a different reason: an item that plays is
    /// already routed to the player by `VideoLink` before the reader is asked,
    /// so a video frame reaching this point is decoration on some other page.
    private static let decorationHosts = [
        "youtube.com", "youtube-nocookie.com", "youtu.be", "vimeo.com",
        "player.vimeo.com", "dailymotion.com", "twitch.tv",
        "spotify.com", "soundcloud.com", "anchor.fm",
        "twitter.com", "x.com", "platform.twitter.com", "facebook.com",
        "instagram.com", "tiktok.com", "reddit.com",
        "disqus.com", "google.com", "googletagmanager.com",
        "doubleclick.net", "googlesyndication.com", "scorecardresearch.com",
        "mailchimp.com", "substack.com/embed", "buttondown.email"
    ]

    private static func isDecoration(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return decorationHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// A frame declared 2 pixels or smaller on either side is a tracking pixel
    /// wearing an iframe. A frame with no declared size is not judged, because
    /// most full-bleed embeds size themselves in CSS.
    private static func isTiny(_ tag: String) -> Bool {
        for name in ["width", "height"] {
            guard let raw = attribute(name, in: tag) else { continue }
            let digits = raw.prefix { $0.isNumber }
            if let value = Int(digits), value <= 2 { return true }
        }
        return false
    }

    // MARK: - Scanning

    private static let framePattern = try! NSRegularExpression(
        pattern: "<iframe\\b[^>]*>", options: [.caseInsensitive])

    private static func frames(in html: String) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        return framePattern.matches(in: html, range: range).compactMap {
            Range($0.range, in: html).map { r in String(html[r]) }
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        // Both quotings, because plenty of pages use neither consistently.
        for pattern in ["\(name)\\s*=\\s*\"([^\"]*)\"", "\(name)\\s*=\\s*'([^']*)'"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let range = Range(match.range(at: 1), in: tag)
            else { continue }
            return String(tag[range])
        }
        return nil
    }
}
