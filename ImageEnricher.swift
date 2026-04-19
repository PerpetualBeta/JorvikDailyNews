import Foundation

/// For items arriving without a feed-supplied image (aggregator items, HN,
/// DF, Tsai, etc.), fetch the target URL's `<head>` and extract `og:image`
/// / `twitter:image` / `<link rel="image_src">`. Only enriches a bounded
/// slice of candidates — the refresh budget can't afford a fetch per
/// archived item.
struct ImageEnricher: Sendable {
    // HTML `<head>` typically fits well under 32 KB; reading a capped slice
    // keeps enrichment cheap on long pages.
    private let maxBytes = 32_768
    private let timeout: TimeInterval = 10

    func enrich(_ items: [FeedItem]) async -> [FeedItem] {
        // Only items missing an image are candidates — no point paying the
        // network cost for items whose feeds already provided one.
        let indexedMissing = items.enumerated().filter { $0.element.imageURL == nil }
        guard !indexedMissing.isEmpty else { return items }

        let me = self
        let resolved = await withTaskGroup(of: (Int, URL?).self) { group in
            for (idx, item) in indexedMissing {
                group.addTask { (idx, await me.extractOGImage(from: item.link)) }
            }
            var acc: [(Int, URL?)] = []
            for await pair in group { acc.append(pair) }
            return acc
        }

        var updated = items
        for (idx, maybeURL) in resolved {
            guard let url = maybeURL else { continue }
            let old = items[idx]
            updated[idx] = FeedItem(
                feedId: old.feedId,
                itemId: old.itemId,
                title: old.title,
                link: old.link,
                summary: old.summary,
                imageURL: url,
                publishedAt: old.publishedAt,
                section: old.section,
                sourceTitle: old.sourceTitle
            )
        }
        return updated
    }

    private func extractOGImage(from url: URL) async -> URL? {
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

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let limited = data.prefix(maxBytes)
        guard let html = String(data: limited, encoding: .utf8)
            ?? String(data: limited, encoding: .isoLatin1) else { return nil }

        // Stop at </head> — saves regex work on full documents.
        let scanRange = html.range(of: "</head>", options: .caseInsensitive).map { html[..<$0.lowerBound] } ?? html[...]
        let head = String(scanRange)

        let patterns = [
            "<meta[^>]+property=[\"']og:image(:secure_url|:url)?[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image(:secure_url|:url)?[\"']",
            "<meta[^>]+name=[\"']twitter:image(:src)?[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']twitter:image(:src)?[\"']",
            "<link[^>]+rel=[\"']image_src[\"'][^>]+href=[\"']([^\"']+)[\"']"
        ]

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
                if let resolved = URL(string: raw, relativeTo: url)?.absoluteURL,
                   let scheme = resolved.scheme, scheme == "http" || scheme == "https" {
                    return resolved
                }
            }
        }
        return nil
    }
}
