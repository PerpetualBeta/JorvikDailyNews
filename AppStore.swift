import Foundation
import Observation

@Observable
@MainActor
final class AppStore {
    let feedStore = FeedStore()
    let editionStore = EditionStore()
    let readStore = ReadStore()
    let updateChecker = JorvikUpdateChecker(repoName: "JorvikDailyNews")
    private let fetcher = FeedFetcher()
    private let discovery = FeedDiscovery()
    private let builder = EditionBuilder()
    private let enricher = ImageEnricher()

    var showAddFeedSheet = false
    var showManageFeedsSheet = false
    var showOPMLImporter = false
    var showOPMLExporter = false
    var selectedArticle: FeedItem?
    var isRefreshing = false
    var isImporting = false
    var lastRefreshError: String?
    var lastImportSummary: String?
    var pageIndex: Int = 0

    var totalPages: Int {
        guard let edition = editionStore.today else { return 1 }
        return max(1, 1 + edition.sections.count)
    }

    var currentPageTitle: String {
        guard let edition = editionStore.today else { return "Front Page" }
        if pageIndex == 0 { return "Front Page" }
        let idx = pageIndex - 1
        guard idx < edition.sections.count else { return "Front Page" }
        return edition.sections[idx].name
    }

    /// Open an article in the reader and mark it read. Single entry point so
    /// every headline click — lead, secondary, brief, section card — gets the
    /// same treatment.
    func openArticle(_ item: FeedItem) {
        readStore.markRead(item.itemId)
        selectedArticle = item
    }

    func goToPage(_ index: Int) {
        let clamped = max(0, min(index, totalPages - 1))
        if pageIndex != clamped { pageIndex = clamped }
    }

    func nextPage() { goToPage(pageIndex + 1) }
    func previousPage() { goToPage(pageIndex - 1) }
    func goToFrontPage() { goToPage(0) }

    func onLaunch() async {
        // Kick the update checker on the shipping schedule; it manages its
        // own cadence and persists its last-check timestamp.
        updateChecker.checkOnSchedule()

        guard !feedStore.feeds.isEmpty else { return }
        let needsPublish = !editionStore.hasTodayEdition() || (editionStore.today?.isEmpty ?? true)
        if needsPublish {
            await refreshAndPublish()
        }
    }

    func refreshAndPublish() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }

        // Paused feeds are held back from fetch; their cached items will be
        // stripped from the rebuilt edition via `applyPauseFilter` paths.
        let feeds = feedStore.feeds.filter { !$0.isPaused }
        let fetcher = self.fetcher
        let discovery = self.discovery

        let results = await withTaskGroup(of: (Feed, Result<FetchOutcome, Error>).self) { group in
            for feed in feeds {
                group.addTask {
                    await Self.fetchSelfHealing(feed, fetcher: fetcher, discovery: discovery)
                }
            }
            var acc: [(Feed, Result<FetchOutcome, Error>)] = []
            for await pair in group { acc.append(pair) }
            return acc
        }

        var allItems: [FeedItem] = []
        var errors: [String] = []

        for (feed, result) in results {
            switch result {
            case .success(let outcome):
                allItems.append(contentsOf: outcome.fetched.items)
                if outcome.resolvedURL != feed.url {
                    feedStore.updateURL(feedId: feed.id, url: outcome.resolvedURL)
                }
                if !outcome.fetched.title.isEmpty && feed.title != outcome.fetched.title {
                    feedStore.updateTitle(feedId: feed.id, title: outcome.fetched.title)
                }
            case .failure(let error):
                errors.append("\(feed.url.host ?? feed.url.absoluteString): \(error.localizedDescription)")
            }
        }

        // Enrich image-less top candidates with og:image / twitter:image
        // extracted from the target article. Capped at the top 24 by date so
        // aggregator items (HN, DF, Tsai, Objective-See) pick up a thumbnail
        // from the actual article page rather than rendering text-only.
        let enrichCap = 24
        let sortedByDate = allItems.sorted { $0.publishedAt > $1.publishedAt }
        let topSlice = Array(sortedByDate.prefix(enrichCap))
        let tail = Array(sortedByDate.dropFirst(enrichCap))
        let enrichedSlice = await enricher.enrich(topSlice)
        let merged = enrichedSlice + tail

        let edition = builder.build(from: merged, date: Date())
        editionStore.save(edition)
        // Clamp page index if the new edition has fewer pages than we were on.
        if pageIndex >= totalPages { pageIndex = 0 }

        if allItems.isEmpty && !errors.isEmpty {
            lastRefreshError = errors.joined(separator: "\n")
        }
    }

    func addFeed(url: URL, section: String) async {
        let feed = Feed(url: url, section: section.trimmingCharacters(in: .whitespaces))
        feedStore.add(feed)
        await refreshAndPublish()
    }

    /// Discover a feed from an arbitrary URL (feed URL or page URL), then add it.
    /// Returns the feed actually added so the caller can surface its title.
    func discoverAndAdd(url: URL, section: String) async throws -> DiscoveredFeed {
        let candidates = try await discovery.discover(from: url)
        guard let first = candidates.first else { throw FeedDiscoveryError.noFeedsFound }
        await addFeed(url: first.url, section: section)
        return first
    }

    func removeFeed(_ feed: Feed) async {
        feedStore.remove(feed)
        await refreshAndPublish()
    }

    /// Toggle pause for a feed. Pausing strips that feed's items from today's
    /// edition instantly via a local rebuild (no network round-trip).
    /// Un-pausing triggers a full refresh so the feed's items come back.
    func togglePause(_ feed: Feed) async {
        let newPaused = !feed.isPaused
        feedStore.setPaused(feedId: feed.id, paused: newPaused)
        if newPaused {
            rebuildCachedEditionExcludingPaused()
        } else {
            await refreshAndPublish()
        }
    }

    /// Re-slot today's edition from its cached items, dropping anything from
    /// currently-paused feeds. Used when the user pauses a feed — avoids the
    /// cost of a full refetch.
    private func rebuildCachedEditionExcludingPaused() {
        guard let edition = editionStore.today else { return }
        let pausedIds = Set(feedStore.feeds.filter { $0.isPaused }.map { $0.id })
        var all: [FeedItem] = []
        if let lead = edition.lead { all.append(lead) }
        all.append(contentsOf: edition.secondaries)
        all.append(contentsOf: edition.briefs)
        all.append(contentsOf: edition.sections.flatMap { $0.items })
        let kept = all.filter { !pausedIds.contains($0.feedId) }
        let rebuilt = builder.build(from: kept, date: edition.date)
        editionStore.save(rebuilt)
        if pageIndex >= totalPages { pageIndex = 0 }
    }

    // MARK: - OPML import

    func importOPML(from url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        lastImportSummary = nil
        defer { isImporting = false }

        guard let data = try? Data(contentsOf: url) else {
            lastImportSummary = "Couldn\u{2019}t read that file."
            return
        }
        let importer = OPMLImporter()
        let entries = importer.parse(data: data)
        guard !entries.isEmpty else {
            lastImportSummary = "No feeds found in that OPML file."
            return
        }
        let candidates = entries.map {
            Feed(url: $0.url, section: $0.section, title: $0.title)
        }
        let (added, skipped) = feedStore.importFeeds(candidates)
        if added == 0 {
            lastImportSummary = "All \(skipped) feed\(skipped == 1 ? "" : "s") were already in your list."
        } else {
            let dupNote = skipped == 0 ? "" : " \u{00B7} \(skipped) already present"
            lastImportSummary = "Added \(added) feed\(added == 1 ? "" : "s")\(dupNote)"
        }
        if added > 0 {
            await refreshAndPublish()
        }
    }

    // MARK: - Self-healing fetch

    struct FetchOutcome: Sendable {
        let fetched: FetchedFeed
        let resolvedURL: URL
    }

    /// Fetch a feed. If the stored URL returns content that can't be parsed as
    /// a feed (e.g. the user supplied a site URL, or a site moved its feed),
    /// try discovery on the same URL and retry with the discovered feed URL.
    private nonisolated static func fetchSelfHealing(
        _ feed: Feed,
        fetcher: FeedFetcher,
        discovery: FeedDiscovery
    ) async -> (Feed, Result<FetchOutcome, Error>) {
        do {
            let fetched = try await fetcher.fetch(feed)
            return (feed, .success(FetchOutcome(fetched: fetched, resolvedURL: feed.url)))
        } catch FeedFetchError.parseFailure {
            guard let found = try? await discovery.discover(from: feed.url).first,
                  found.url != feed.url else {
                return (feed, .failure(FeedFetchError.parseFailure))
            }
            let healed = Feed(
                id: feed.id,
                url: found.url,
                section: feed.section,
                title: feed.title,
                lastSeenItemIds: feed.lastSeenItemIds
            )
            do {
                let fetched = try await fetcher.fetch(healed)
                return (feed, .success(FetchOutcome(fetched: fetched, resolvedURL: found.url)))
            } catch {
                return (feed, .failure(error))
            }
        } catch {
            return (feed, .failure(error))
        }
    }
}
