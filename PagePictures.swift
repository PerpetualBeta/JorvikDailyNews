import Foundation

/// Decides which cards on one page must run without their picture, because
/// the picture is already on that page.
///
/// A newspaper does not print the same photograph twice on a spread, and the
/// paper of 9 September 2026 printed one arXiv logo thirteen times:
///
///     13x  https://arxiv.org/static/browse/0.3.4/images/arxiv-logo-fb.png
///
/// That is not a launch-day accident. Every arXiv paper carries the same
/// `og:image`, so any day with a run of them produces a wall of identical
/// grey logos. The Apple case is the harder one: three copies of a hero shot
/// under three different URLs, which no comparison of addresses can catch.
///
/// The rule is deliberately positional and not global. The same picture on
/// page 4 and page 11 is fine — nobody sees both at once — so this only asks
/// what is already on THIS page.
enum PagePictures {

    /// The ids of items whose picture repeats one already used on this page.
    ///
    /// `signature` is passed in rather than reached for, so this is a pure
    /// function of its arguments and a test can hand it whatever it likes.
    /// It returns nil for a picture never yet downloaded, in which case only
    /// the address is compared — see the note on timing below.
    static func repeats(in items: [FeedItem],
                        signature: (URL) -> PictureSignature?) -> Set<String> {
        var seenURLs = Set<String>()
        var seenSignatures: [PictureSignature] = []
        var repeated = Set<String>()

        for item in items {
            guard let url = item.imageURL else { continue }
            let key = url.absoluteString
            let sig = signature(url)

            if seenURLs.contains(key) {
                repeated.insert(item.itemId)
            } else if let sig, seenSignatures.contains(where: { $0.isSamePicture(as: sig) }) {
                repeated.insert(item.itemId)
            }

            // Recorded whether or not it was kept. A page holding three copies
            // of one photograph must lose two of them, and the second and
            // third are not always within threshold of each other even when
            // both match the first — the Apple trio measured 4, 6 and 8 bits
            // apart. Comparing against everything seen collapses the chain;
            // comparing only against what was kept leaves one copy behind.
            seenURLs.insert(key)
            if let sig { seenSignatures.append(sig) }
        }
        return repeated
    }
}
