import Foundation

/// For items arriving without a feed-supplied image or standfirst (aggregator
/// items, HN, DF, Tsai, etc.), fetch the target URL's `<head>` and take what
/// the page says about itself: `og:image` / `twitter:image` / `<link
/// rel="image_src">` for the picture, `og:description` / `twitter:description`
/// / `<meta name="description">` for the text. Only enriches a bounded slice of
/// candidates — the refresh budget can't afford a fetch per archived item.
///
/// The description matters most for Hacker News, whose items carry only
/// `Article URL: / Comments URL: / Points:` boilerplate where a standfirst
/// would go. `FeedFetcher.cleanSummary` strips that, correctly, which used to
/// leave those items with no text at all — 165 of 178 in one measured day, and
/// a blank lead whenever one of them was promoted.
struct ImageEnricher: Sendable {
    // HTML `<head>` typically fits well under 32 KB; reading a capped slice
    // keeps enrichment cheap on long pages.
    private let maxBytes = 32_768
    private let timeout: TimeInterval = 10

    /// What a page's own head says about itself.
    struct PageMeta: Sendable {
        var image: URL?
        var description: String?
    }

    func enrich(_ items: [FeedItem]) async -> [FeedItem] {
        // A candidate is missing an image OR a standfirst. One fetch answers
        // both questions, so an item short of either is worth the round trip;
        // an item that already has both is not.
        let indexedMissing = items.enumerated().filter {
            $0.element.imageURL == nil || $0.element.summary.isEmpty
        }
        guard !indexedMissing.isEmpty else { return items }

        let me = self
        let resolved = await withTaskGroup(of: (Int, PageMeta).self) { group in
            for (idx, item) in indexedMissing {
                group.addTask { (idx, await me.extractMeta(from: item.link)) }
            }
            var acc: [(Int, PageMeta)] = []
            for await pair in group { acc.append(pair) }
            return acc
        }

        var updated = items
        for (idx, meta) in resolved {
            let old = items[idx]
            // Never overwrite what the feed supplied. The page's own metadata
            // is a fallback for what is missing, not a better source.
            let image = old.imageURL ?? meta.image
            let summary = old.summary.isEmpty ? (meta.description ?? "") : old.summary
            guard image != old.imageURL || summary != old.summary else { continue }
            updated[idx] = FeedItem(
                feedId: old.feedId,
                itemId: old.itemId,
                title: old.title,
                link: old.link,
                summary: summary,
                imageURL: image,
                publishedAt: old.publishedAt,
                section: old.section,
                sourceTitle: old.sourceTitle
            )
        }
        return updated
    }

    private func extractMeta(from url: URL) async -> PageMeta {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        // Hint to the server that we only need the first N bytes. Servers that
        // honour it save bandwidth; servers that don't just send the full body,
        // which we still cap locally by stopping parsing at the </head> tag.
        request.setValue("bytes=0-\(maxBytes)", forHTTPHeaderField: "Range")
        request.timeoutInterval = timeout

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return PageMeta() }
        let limited = data.prefix(maxBytes)
        guard let html = String(data: limited, encoding: .utf8)
            ?? String(data: limited, encoding: .isoLatin1) else { return PageMeta() }

        // Stop at </head> — saves regex work on full documents.
        let scanRange = html.range(of: "</head>", options: .caseInsensitive).map { html[..<$0.lowerBound] } ?? html[...]
        let head = String(scanRange)

        // Some sites declare their APP ICON as their social image. `what2do.me`
        // publishes the same file twice:
        //
        //   <meta property="og:image" content="/icons/icon-512.png" />
        //   <link rel="icon" sizes="512x512" href="/icons/icon-512.png" />
        //
        // That is the site telling us, in its own head, that the picture is an
        // icon rather than article art — a stated fact, not a guess about
        // squareness or pixel count. Reject any candidate whose URL is also
        // declared as a site icon, and try the next candidate instead.
        //
        // The comparison must be an EXACT url match, not a resemblance.
        // `ruby-lang.org` serves `/images/og-image.png` as its social image and
        // `/images/icon-192.png` as its icon: a purpose-made social card that
        // happens to be a logo. A "square and small and flat" heuristic would
        // wrongly throw that away. This test leaves it alone.
        let icons = iconURLs(in: head, relativeTo: url)
        return PageMeta(
            image: imageCandidates(in: head, relativeTo: url).first { !icons.contains($0) },
            description: description(in: head)
        )
    }

    /// What the page says it is about, in the order the sources are worth
    /// trusting. Run through `Standfirst.extract` like any other body text:
    /// a description is usually plain prose but some sites leave entities or a
    /// stray tag in it, and this is the one path that handles both.
    private func description(in head: String) -> String? {
        let patterns = [
            "<meta[^>]+property=[\"']og:description[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:description[\"']",
            "<meta[^>]+name=[\"']twitter:description[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']twitter:description[\"']",
            "<meta[^>]+name=[\"']description[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']description[\"']"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(head.startIndex..., in: head)
            guard let match = regex.firstMatch(in: head, range: range), match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: head) else { continue }
            let text = Standfirst.extract(from: String(head[r]))
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Every picture the head offers as a social image, in preference order,
    /// deduplicated.
    private func imageCandidates(in head: String, relativeTo url: URL) -> [URL] {
        let patterns = [
            "<meta[^>]+property=[\"']og:image(:secure_url|:url)?[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image(:secure_url|:url)?[\"']",
            "<meta[^>]+name=[\"']twitter:image(:src)?[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']twitter:image(:src)?[\"']",
            "<link[^>]+rel=[\"']image_src[\"'][^>]+href=[\"']([^\"']+)[\"']"
        ]

        var found: [URL] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(head.startIndex..., in: head)
            guard let match = regex.firstMatch(in: head, range: range) else { continue }
            // The content/href capture group is whichever group isn't the
            // optional suffix — last group with any value.
            for g in stride(from: match.numberOfRanges - 1, through: 1, by: -1) {
                guard let r = Range(match.range(at: g), in: head) else { continue }
                let raw = String(head[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard raw.isEmpty == false, !raw.hasPrefix(":") else { continue }
                if let resolved = Self.absoluteWebURL(raw, relativeTo: url) {
                    if !found.contains(resolved) { found.append(resolved) }
                    break
                }
            }
        }
        return found
    }

    /// Every URL the head declares as a site icon. Covers `icon`,
    /// `shortcut icon`, `apple-touch-icon`, `apple-touch-icon-precomposed` and
    /// `mask-icon` in one sweep, because each spells "icon" in its `rel`.
    private func iconURLs(in head: String, relativeTo url: URL) -> Set<URL> {
        guard let linkRegex = try? NSRegularExpression(
            pattern: "<link[^>]*rel=[\"'][^\"']*icon[^\"']*[\"'][^>]*>",
            options: .caseInsensitive
        ), let hrefRegex = try? NSRegularExpression(
            pattern: "href=[\"']([^\"']+)[\"']",
            options: .caseInsensitive
        ) else { return [] }

        var icons: Set<URL> = []
        let range = NSRange(head.startIndex..., in: head)
        for match in linkRegex.matches(in: head, range: range) {
            guard let tagRange = Range(match.range, in: head) else { continue }
            let tag = String(head[tagRange])
            let tagNSRange = NSRange(tag.startIndex..., in: tag)
            guard let href = hrefRegex.firstMatch(in: tag, range: tagNSRange),
                  href.numberOfRanges > 1,
                  let r = Range(href.range(at: 1), in: tag) else { continue }
            let raw = String(tag[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved = Self.absoluteWebURL(raw, relativeTo: url) { icons.insert(resolved) }
        }
        return icons
    }

    /// Resolve a possibly-relative href against the page, keeping only http(s).
    private static func absoluteWebURL(_ raw: String, relativeTo url: URL) -> URL? {
        guard !raw.isEmpty, !raw.hasPrefix(":"),
              let resolved = URL(string: raw, relativeTo: url)?.absoluteURL,
              let scheme = resolved.scheme, scheme == "http" || scheme == "https"
        else { return nil }
        return resolved
    }
}
