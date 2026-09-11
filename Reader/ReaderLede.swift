import Foundation

/// Decides whether the reader should open with the paper's own hero picture.
///
/// **Why this is needed.** A site's lede photograph usually sits outside the
/// `<article>` element, so Readability treats it as page furniture and drops
/// it. Its *caption* often survives as a paragraph, which is what makes the
/// absence read as a fault rather than a choice: the words "Credit: United
/// Launch Alliance" appear under nothing.
///
/// Measured over 24 items from one day's paper, all of which had a hero on
/// their card: 8 articles opened with a picture, **7 had their first image at
/// block 5, 7, 15, 23, 23, 27 or 29**, and 8 had no images at all. So the
/// majority of articles opened with nothing, while the app already held the
/// right photograph and had usually already decoded it for the front page.
///
/// **This is a product decision, not a repair.** Nothing was malfunctioning:
/// the reader was faithfully showing what Readability returned. It does mean
/// the reader shows one thing the extracted article did not contain, which is
/// a real if small weakening of "the article and only the article".
enum ReaderLede {

    /// How far into the article a picture still counts as its opening one.
    ///
    /// Four blocks covers a heading, a standfirst and a first paragraph. Beyond
    /// that a picture is illustrating the body rather than opening the piece,
    /// and the article reads as having no lede.
    static let ledeWindow = 4

    /// The hero to draw above the article, or nil to draw nothing.
    ///
    /// - Parameter hero: the picture the paper already has for this item.
    /// - Parameter blockKinds: every block's kind, in order.
    /// - Parameter blockSources: every block's `src`, in the same order, so an
    ///   early picture can be compared against the hero.
    static func hero(_ hero: URL?,
                     blockKinds: [String],
                     blockSources: [String?]) -> URL? {
        guard let hero else { return nil }

        // Already opens with a picture: leave it alone. Adding one would put
        // two photographs at the top, and on a site whose hero DOES survive
        // they would usually be the same photograph twice.
        if let first = blockKinds.firstIndex(of: "image"), first < ledeWindow {
            return nil
        }

        // Second guard, for the case the window misses: the same picture
        // appearing anywhere as an article image. Compared without the query,
        // because a CDN appends sizing parameters to the same file and the two
        // would otherwise look like different pictures.
        let heroKey = key(hero.absoluteString)
        for (kind, src) in zip(blockKinds, blockSources)
        where kind == "image" && src.map({ key($0) }) == heroKey {
            return nil
        }
        return hero
    }

    /// A picture's identity for comparison.
    ///
    /// Scheme and query are dropped, because a CDN serves the same file over
    /// either scheme and with sizing parameters appended.
    ///
    /// **And a transform URL is unwrapped to the file it transforms.** That is
    /// what this originally missed. Substack serves both the card's hero and
    /// the article's own copy through `substackcdn.com/image/fetch/…`, with the
    /// real file percent-encoded at the end of the path and *different*
    /// transform parameters in front of it:
    ///
    ///     …/image/fetch/$s_!k441!,w_1200,h_675,c_fill,f_jpg,…/https%3A%2F%2F…%2F6ffa9394….png
    ///     …/image/fetch/w_1456,c_limit,f_webp,…/https%3A%2F%2F…%2F6ffa9394….png
    ///
    /// Same host, same picture, different path — so the reader showed the same
    /// chart twice, once as the lede it had supplied and once as the article's
    /// own. Unwrapping to the embedded original identifies them as one file.
    /// The same shape covers Cloudinary, imgproxy and WordPress's `i0.wp.com`,
    /// all of which put the origin inside the path.
    static func key(_ urlString: String) -> String {
        let unwrapped = embeddedOriginal(in: urlString) ?? urlString
        guard var c = URLComponents(string: unwrapped) else { return unwrapped.lowercased() }
        if let photon = photonOriginal(c), let inner = URLComponents(string: photon) { c = inner }
        return ((c.host ?? "") + c.path).lowercased()
    }

    /// The innermost `http(s)://…` inside a URL, if one is nested in its path.
    ///
    /// The LAST occurrence, because transforms nest: the outermost is the CDN
    /// and the innermost is the file. Percent-decoded once, which is how these
    /// are written; a doubly-encoded one falls back to the outer URL, which is
    /// no worse than before.
    static func embeddedOriginal(in urlString: String) -> String? {
        let decoded = urlString.removingPercentEncoding ?? urlString
        // Beyond the first character, so the URL's own scheme is not matched.
        guard let range = decoded.range(of: "http", options: .backwards),
              range.lowerBound > decoded.startIndex else { return nil }
        let candidate = String(decoded[range.lowerBound...])
        guard candidate.hasPrefix("http://") || candidate.hasPrefix("https://"),
              URLComponents(string: candidate)?.host != nil else { return nil }
        return candidate
    }

    /// WordPress's Photon embeds the origin with **no scheme** —
    /// `i0.wp.com/example.com/a/pic.jpg` — so the search above cannot see it.
    ///
    /// Handled by name rather than by guessing, because "the first path
    /// segment looks like a hostname" would also match a path like
    /// `/v1.2/pic.jpg`. Narrow and certain beats general and wrong.
    private static let photonHosts = ["i0.wp.com", "i1.wp.com", "i2.wp.com", "i3.wp.com", "i.wp.com"]

    private static func photonOriginal(_ c: URLComponents) -> String? {
        guard let host = c.host?.lowercased(), photonHosts.contains(host) else { return nil }
        let path = c.path.hasPrefix("/") ? String(c.path.dropFirst()) : c.path
        guard let slash = path.firstIndex(of: "/"), path[..<slash].contains(".") else { return nil }
        return "https://" + path
    }
}
