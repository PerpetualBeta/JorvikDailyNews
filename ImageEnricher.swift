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
    /// How many article pages to fetch at once.
    ///
    /// Eight because each request is mostly waiting on a remote server rather
    /// than on this machine, so a small window still keeps the pipe full: at a
    /// measured 0.3s per page, 420 candidates take about 16s, against a
    /// refresh budget of 300s. The point is the peak, not the total.
    private static let concurrentPageFetches = 8

    /// What a page's own head says about itself.
    struct PageMeta: Sendable {
        var image: URL?
        var description: String?
        /// Why this page yielded nothing, when it yielded nothing.
        ///
        /// `extractMeta` had three silent `return PageMeta()` paths, so a page
        /// that could not be fetched, a page whose bytes would not decode, and
        /// a page that simply has no social image were the same event as far as
        /// the log was concerned: no event at all. On a Hacker News front page
        /// that matters, because most of those links genuinely have no picture
        /// and a few are misses, and the two need different answers.
        var failure: String?
    }

    /// Enriched items, plus the ids worth asking about again.
    ///
    /// The caller records every item it asks about so it never asks twice,
    /// which is right for a page that declares no picture: the answer cannot
    /// change today. It is wrong for a page that timed out or refused the
    /// connection, and that was indistinguishable until `PageMeta` started
    /// carrying a reason. Three of forty sampled picture-less items on
    /// 2026-09-09 had failed to fetch rather than having nothing to give, and
    /// each was written off for the rest of the day on one bad round trip.
    struct Enrichment: Sendable {
        let items: [FeedItem]
        let retryable: Set<String>
    }

    func enrich(_ items: [FeedItem]) async -> Enrichment {
        // A candidate is missing an image OR a standfirst. One fetch answers
        // both questions, so an item short of either is worth the round trip;
        // an item that already has both is not.
        let indexedMissing = items.enumerated().filter {
            $0.element.imageURL == nil || $0.element.summary.isEmpty
        }
        guard !indexedMissing.isEmpty else { return Enrichment(items: items, retryable: []) }

        let me = self
        // A sliding window, not one task per candidate.
        //
        // A refresh can offer 420 candidates, and adding a task for each fired
        // 420 page requests at once. Measured on 2026-09-09, every real
        // WebKit failure on this machine landed within seconds of a refresh
        // completing, and a refresh's peak was 254 feed fetches plus this
        // burst. WebKit starts its renderer by asking the same process for
        // resources at the same moment, and the failure signature was that the
        // provisional load never began at all.
        //
        // That link is not proven. The burst is worth removing regardless: it
        // is 420 concurrent connections in a desktop reader, which is
        // indefensible on its own terms.
        let resolved = await withTaskGroup(of: (Int, PageMeta).self) { group in
            var next = indexedMissing.makeIterator()
            var inFlight = 0
            while inFlight < Self.concurrentPageFetches, let (idx, item) = next.next() {
                group.addTask { (idx, await me.extractMeta(from: item.link)) }
                inFlight += 1
            }
            var acc: [(Int, PageMeta)] = []
            while let pair = await group.next() {
                acc.append(pair)
                if let (idx, item) = next.next() {
                    group.addTask { (idx, await me.extractMeta(from: item.link)) }
                }
            }
            return acc
        }

        // One line per pass, not one per page. 420 candidates in a refresh
        // would drown the log; the buckets are what make a sparse front page
        // interpretable.
        var gainedImage = 0, gainedSummary = 0
        var noneDeclared = 0, iconOnly = 0, fetchFailed = 0, otherFailure = 0
        var retryable: Set<String> = []
        for (idx, meta) in resolved {
            if meta.image != nil, items[idx].imageURL == nil { gainedImage += 1 }
            if meta.description?.isEmpty == false, items[idx].summary.isEmpty { gainedSummary += 1 }
            switch meta.failure {
            case .some(let f) where f.hasPrefix("declares no"): noneDeclared += 1
            case .some(let f) where f.hasPrefix("all "): iconOnly += 1
            case .some(let f) where f.hasPrefix("fetch failed"):
                fetchFailed += 1
                retryable.insert(items[idx].itemId)
            case .some: otherFailure += 1
            case .none: break
            }
        }
        jdnLog("enrich: \(indexedMissing.count) page(s) asked — \(gainedImage) gained a picture, "
               + "\(gainedSummary) a standfirst; \(noneDeclared) declare none, "
               + "\(iconOnly) offer only their site icon, \(fetchFailed) would not fetch"
               + (otherFailure > 0 ? ", \(otherFailure) other" : ""))

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
        return Enrichment(items: updated, retryable: retryable)
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

        let fetched: Data
        do {
            (fetched, _) = try await URLSession.shared.data(for: request)
        } catch {
            return PageMeta(failure: "fetch failed: \(error.localizedDescription)")
        }
        let limited = fetched.prefix(maxBytes)
        guard let html = String(data: limited, encoding: .utf8)
            ?? String(data: limited, encoding: .isoLatin1) else {
            return PageMeta(failure: "\(limited.count) bytes decode as neither UTF-8 nor Latin-1")
        }

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
        let candidates = imageCandidates(in: head, relativeTo: url)
        let picked = candidates.first { !icons.contains($0) }
        // Distinguish "this page declares no social image" from "every image it
        // declares is its own site icon". Measured on a Hacker News front page
        // 2026-09-09: of twelve items with no picture, nine of the target pages
        // genuinely declare none, so the sparse look was mostly honest and
        // three were misses. Only a count separates those two answers.
        var why: String?
        if picked == nil {
            why = candidates.isEmpty
                ? "declares no og:image or twitter:image"
                : "all \(candidates.count) candidate(s) are also declared as site icons"
        }
        return PageMeta(
            image: picked,
            description: description(in: head),
            failure: why
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
            // Non-empty is not enough. A page can declare a description that
            // its own CMS has cut off mid-phrase, and rendering that under a
            // headline looks like our fault rather than theirs: Global Times
            // served `description` as exactly "The flames of a", which JDN
            // then printed as the lead's whole standfirst. Too short to be a
            // sentence means no standfirst, and lead selection prefers an item
            // that has one.
            guard !text.isEmpty else { continue }
            let words = text.split(whereSeparator: \.isWhitespace).count
            guard words >= Standfirst.minDescriptionWords else {
                jdnLog("enrich: description of \(words) word(s) is too short to be a standfirst — \(text.prefix(60))")
                continue
            }
            return text
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
