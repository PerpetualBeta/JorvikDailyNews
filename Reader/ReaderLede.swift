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

    /// A picture's identity for comparison: scheme and query dropped, because a
    /// CDN serves the same file over either scheme and with sizing parameters
    /// appended.
    static func key(_ urlString: String) -> String {
        guard let c = URLComponents(string: urlString) else { return urlString }
        return ((c.host ?? "") + c.path).lowercased()
    }
}
