import Foundation

struct DiscoveredFeed: Hashable, Identifiable {
    let url: URL
    let title: String?
    var id: URL { url }
}

enum FeedDiscoveryError: Error, LocalizedError {
    case fetchFailed(String)
    case noFeedsFound
    case alreadyAdded(existingTitle: String)

    var errorDescription: String? {
        switch self {
        case .fetchFailed(let msg): "Couldn\u{2019}t reach that URL: \(msg)"
        case .noFeedsFound: "No feeds found on that page"
        case .alreadyAdded(let title): "You already subscribe to \u{201C}\(title)\u{201D}"
        }
    }
}

final class FeedDiscovery: Sendable {
    // Common paths probed when a site's HTML has no <link rel="alternate"> tags.
    // Order matters: the first hit wins.
    private static let fallbackPaths = [
        "/feed", "/feed/", "/rss", "/rss.xml", "/atom.xml",
        "/feed.xml", "/index.xml", "/feeds/posts/default"
    ]

    func discover(from input: URL) async throws -> [DiscoveredFeed] {
        let (data, response) = try await fetch(input)

        if bodyLooksLikeFeed(data) {
            let title = parseFeedTitle(data)
            let finalURL = (response.url ?? input)
            return [DiscoveredFeed(url: finalURL, title: title)]
        }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let base = response.url ?? input
        let fromLinks = parseAlternateLinks(in: html, baseURL: base)
        if !fromLinks.isEmpty { return fromLinks }

        for path in Self.fallbackPaths {
            guard let probe = URL(string: path, relativeTo: base)?.absoluteURL else { continue }
            guard let (probeData, probeResponse) = try? await fetch(probe) else { continue }
            if bodyLooksLikeFeed(probeData) {
                let title = parseFeedTitle(probeData)
                let finalURL = probeResponse.url ?? probe
                return [DiscoveredFeed(url: finalURL, title: title)]
            }
        }

        return []
    }

    // MARK: - Networking

    private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("JorvikDailyNews/0.1 (+https://jorviksoftware.cc)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, text/html;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                throw FeedDiscoveryError.fetchFailed("HTTP \(http.statusCode)")
            }
            return (data, response)
        } catch let e as FeedDiscoveryError {
            throw e
        } catch {
            throw FeedDiscoveryError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Feed sniffing

    private func bodyLooksLikeFeed(_ data: Data) -> Bool {
        let prefix = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
        return prefix.contains("<rss") || prefix.contains("<feed")
    }

    private func parseFeedTitle(_ data: Data) -> String? {
        let prefix = String(data: data.prefix(8192), encoding: .utf8) ?? ""
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>([^<]+)</title>",
            options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(prefix.startIndex..., in: prefix)
        guard let match = regex.firstMatch(in: prefix, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: prefix) else { return nil }
        let raw = String(prefix[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    // MARK: - HTML link parsing

    private func parseAlternateLinks(in html: String, baseURL: URL) -> [DiscoveredFeed] {
        guard let headEnd = html.range(of: "</head>", options: .caseInsensitive)?.upperBound else {
            return parseLinkTags(in: html, baseURL: baseURL)
        }
        let head = String(html[..<headEnd])
        return parseLinkTags(in: head, baseURL: baseURL)
    }

    private func parseLinkTags(in html: String, baseURL: URL) -> [DiscoveredFeed] {
        guard let regex = try? NSRegularExpression(
            pattern: "<link\\s+([^>]*?)/?>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<URL>()
        var results: [DiscoveredFeed] = []

        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: html) else { continue }
            let attrs = String(html[r])
            let lower = attrs.lowercased()

            guard lower.contains("alternate") else { continue }
            guard lower.contains("application/rss+xml") || lower.contains("application/atom+xml") else { continue }

            guard let href = extractAttr("href", from: attrs),
                  let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  !seen.contains(resolved) else { continue }

            seen.insert(resolved)
            results.append(DiscoveredFeed(url: resolved, title: extractAttr("title", from: attrs)))
        }
        return results
    }

    private func extractAttr(_ name: String, from attrs: String) -> String? {
        let patterns = [
            "\(name)\\s*=\\s*\"([^\"]*)\"",
            "\(name)\\s*=\\s*'([^']*)'",
            "\(name)\\s*=\\s*([^\\s>]+)"
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else { continue }
            let range = NSRange(attrs.startIndex..., in: attrs)
            if let m = regex.firstMatch(in: attrs, range: range),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: attrs) {
                return String(attrs[r])
            }
        }
        return nil
    }
}
