import Foundation
import Observation
import AppKit

@Observable
@MainActor
final class AppStore {
    let feedStore = FeedStore()
    let editionStore = EditionStore()
    let readStore = ReadStore()
    let classifier = ArticleClassifier()
    private let fetcher = FeedFetcher()
    private let discovery = FeedDiscovery()
    private let builder = EditionBuilder()
    private let enricher = ImageEnricher()
    /// Items a page has already been asked about, so one that simply has no
    /// `og:image` is not fetched again every time the paper reflows.
    private var enrichmentAttempted: Set<String> = []
    private var isToppingUp = false
    /// How many times each item has been re-asked after a failed fetch.
    ///
    /// A transient failure is un-marked so the page can be asked again, and
    /// without a cap that is an infinite loop: the item is unasked, it has no
    /// picture, so `nextBatch` picks it, it fails, it is un-marked again.
    /// Observed on 2026-09-09 within forty minutes of adding the retry — two
    /// dead URLs re-fetched every ten seconds indefinitely.
    ///
    /// `ImageCache` had already solved this for pictures with a cool-off, and
    /// a cool-off alone only slows the loop down. What ends it is a count.
    private var enrichmentRetries: [String: Int] = [:]
    /// Three attempts in total: the first, then two retries. Enough for a
    /// server having a moment, few enough that a permanently dead URL costs
    /// three round trips a day rather than one every ten seconds.
    private static let maxEnrichmentRetries = 2

    /// When the in-flight refresh began, so it can report its own duration.
    /// The watchdog's margin is only trustworthy while somebody can see it.
    private var refreshStarted = Date()

    /// How many of the newest items in a section the REFRESH enriches. This is
    /// only a primer, so the paper opens with pictures before anyone has
    /// scrolled; the target below is what actually decides how far enrichment
    /// goes.
    private static let enrichCapPerSection = 24
    /// When the day-scoped state was last cleared, so it happens once a day
    /// and not once per refresh. See `DayRollover`.
    private var lastDayRollover: Date?

    /// Only for the log line that names the edition being dropped at midnight.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    /// How many failing feeds to name before summarising the rest.
    ///
    /// Twenty, sized from a measurement rather than a guess: every one of the
    /// 254 subscriptions was fetched on 2026-09-09 and nineteen failed. Three
    /// was the first guess, then eight, both set while assuming a few dozen
    /// feeds. Now that each failure gets its own line the only thing this
    /// bounds is a runaway, so it can afford to sit above the real figure.
    private static let loggedFetchErrors = 20
    /// How many feeds to fetch at once.
    ///
    /// Sixteen, and the number that matters is the one it replaces: with 254
    /// subscriptions the old code put 254 requests in flight simultaneously,
    /// while `launchctl limit maxfiles` gives a GUI app a soft ceiling of
    /// **256** descriptors and the app already holds about 94 of them. That is
    /// over the line before the enrichment pass adds anything.
    ///
    /// Each fetch is mostly waiting on a remote server, so a window of sixteen
    /// still keeps the pipe full. Measured before the cap: 254 feeds in 21.3s.
    /// The refresh reports its own elapsed time against a 300s budget, so the
    /// cost of this is visible in every log rather than assumed here.
    private static let concurrentFeedFetches = 16

    /// The share of a page's articles that should carry a picture.
    ///
    /// A position cap could not express this. Enriching "the newest 24" meant
    /// the front page took the first 16 of them and the section page, which
    /// shows everything from 17 onward, lived almost entirely outside the
    /// window — measured at 25% coverage against 100% on the front page. The
    /// budget is now the outcome rather than a count: keep fetching until the
    /// page hits the target or the section runs out of pages to ask.
    ///
    /// It is a target, not a promise. A section of Show HN posts, Ask HN
    /// threads and repositories with no artwork anywhere to find will stop
    /// short of it having asked everything, which is the right place to stop:
    /// the loop ends when a section runs out of unasked items, not when the
    /// number is met.
    ///
    /// **0.70, raised from 0.30 on 2026-09-09, and the old value made the whole
    /// top-up a no-op.** The guard skips any section already at target, so with
    /// real coverage measured at 51% to 59% every section was above 0.30 and
    /// nothing was ever topped up. Pictures appeared to "dry up" as items were
    /// read, because hide-read promotes items from deeper in the list and the
    /// only thing that would have fetched their pictures had switched itself
    /// off.
    ///
    /// 0.70 comes from the ceiling rather than from taste. Sampling 40
    /// picture-less unread items and fetching each: **23 declare no `og:image`
    /// or `twitter:image` at all, 14 have one, 3 would not fetch.** So about
    /// 35% of what is missing is recoverable, which on 51% actual coverage puts
    /// the reachable figure near 68%. A target above that would just burn
    /// rounds on pages with nothing to give.
    ///
    /// The comment this replaces said 3 of 30 offered an `og:image`, which is
    /// 10%. Today's sample says 35%. That older figure is what justified a
    /// target low enough to disable the feature, so it is worth re-measuring
    /// rather than trusting either number for long.
    static let imageCoverageTargetDefault = 0.70
    static let imageCoverageKey = "imageCoverageTarget"

    static var imageCoverageTarget: Double {
        let stored = UserDefaults.standard.double(forKey: imageCoverageKey)
        return stored > 0 ? stored : imageCoverageTargetDefault
    }

    /// How many pages one section may be asked about in a single round. Bounds
    /// the burst: a whole section at once is what provokes the throttling that
    /// blanks pictures, and rounds continue anyway until the target is met.
    private static let topUpBatchPerSection = 12

    /// Backstop on the rounds a single top-up may run. `enrichmentAttempted`
    /// shrinks the candidate pool every round so this should never bind, but a
    /// loop that fetches should not rely on "should".
    private static let maxTopUpRounds = 8

    private var hourlyTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

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
    var hideReadItems: Bool = UserDefaults.standard.bool(forKey: "hideReadItems") {
        didSet {
            guard oldValue != hideReadItems else { return }
            UserDefaults.standard.set(hideReadItems, forKey: "hideReadItems")
            recomputeVisibleEdition()
        }
    }

    /// Destination hosts the user never wants to see. An item is filtered out
    /// of the paper when its **resolved link** host matches — independent of
    /// which feed surfaced it, so you can ban one paywalled site without
    /// muting the aggregator (HN etc.) that linked to it. Persisted.
    private(set) var excludedHosts: Set<String> = AppStore.loadExcludedHosts()

    /// In-memory, reflowed edition. The edition on disk is always the full,
    /// unfiltered build; this is what the UI actually renders. Recomputed
    /// when filters change (pause, hide-read) or a fresh edition is saved.
    private(set) var visibleEdition: Edition?

    var totalPages: Int {
        guard let edition = visibleEdition ?? editionStore.today else { return 1 }
        return max(1, 1 + edition.sections.count)
    }

    var currentPageTitle: String {
        guard let edition = visibleEdition ?? editionStore.today else { return "Front Page" }
        if pageIndex == 0 { return "Front Page" }
        let idx = pageIndex - 1
        guard idx < edition.sections.count else { return "Front Page" }
        let name = edition.sections[idx].name
        // A section too big for one page becomes several of the same name, so
        // say which one this is. Counted rather than stored, so an edition
        // saved before this existed still decodes.
        let sameName = edition.sections.enumerated().filter { $0.element.name == name }
        guard sameName.count > 1 else { return name }
        let part = (sameName.firstIndex { $0.offset == idx } ?? 0) + 1
        return "\(name) (\(part) of \(sameName.count))"
    }

    /// How many pages the current section runs to, for anything that wants to
    /// skip a whole section rather than turn a page at a time.
    var currentSectionPageCount: Int {
        guard let edition = visibleEdition ?? editionStore.today, pageIndex > 0 else { return 1 }
        let idx = pageIndex - 1
        guard idx < edition.sections.count else { return 1 }
        let name = edition.sections[idx].name
        return max(1, edition.sections.filter { $0.name == name }.count)
    }

    /// Open an article in the reader and mark it read. Single entry point so
    /// every headline click — lead, secondary, brief, section card — gets the
    /// same treatment. When hide-read is on, reflow the paper so the next
    /// unread item fills the vacated slot by the time the reader closes.
    func openArticle(_ item: FeedItem) {
        readStore.markRead(item.itemId)
        selectedArticle = item
        if hideReadItems {
            recomputeVisibleEdition()
        }
    }

    func goToPage(_ index: Int) {
        let clamped = max(0, min(index, totalPages - 1))
        if pageIndex != clamped { pageIndex = clamped }
    }

    func nextPage() { goToPage(pageIndex + 1) }
    func previousPage() { goToPage(pageIndex - 1) }
    func goToFrontPage() { goToPage(0) }

    func onLaunch() async {
        // Sparkle handles the scheduled update check (see JorvikDailyNewsApp).
        // Rebuild the visible edition from whatever was loaded from disk
        // so filters apply immediately on relaunch.
        recomputeVisibleEdition()

        startHourlyRefresh()

        guard !feedStore.feeds.isEmpty else { return }
        // Always refresh on launch so today-items that published since the
        // last save come in. `refreshAndPublish` will keep the cached
        // edition if the refresh itself returns nothing (offline).
        await refreshAndPublish()
    }

    // MARK: - Hourly auto-refresh

    /// Fires `refreshAndPublish` on each clock-hour boundary (09:00, 10:00, …)
    /// and re-arms after wake-from-sleep, since a Timer scheduled before sleep
    /// can fire late or be skipped entirely on long sleeps.
    private func startHourlyRefresh() {
        scheduleNextHourlyRefresh()

        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleNextHourlyRefresh()
                await self.refreshAndPublish()
            }
        }
    }

    private func scheduleNextHourlyRefresh() {
        hourlyTimer?.invalidate()
        let now = Date()
        guard let nextHour = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return }
        let interval = nextHour.timeIntervalSince(now)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshAndPublish()
                self.scheduleNextHourlyRefresh()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        hourlyTimer = timer
    }

    /// Runs a refresh, and makes sure a refresh cannot wedge the app.
    ///
    /// `isRefreshing` is what stops two refreshes overlapping, and it used to
    /// be cleared by a `defer` inside the work itself. That is only sound if
    /// the work always finishes. One `await` that never returns, and this one
    /// warms a lead image over the network, leaves the flag set for the life of
    /// the process. After that every refresh returns immediately and silently,
    /// the hourly timer and the reader's own button alike, and the paper simply
    /// stops changing. Nothing reported it, because none of this was logged.
    ///
    /// So the work races a clock, and the flag is cleared out here rather than
    /// in there. Abandoning a refresh does not stop it, so it is also
    /// cancelled, and it checks for that before it publishes: that is what
    /// stops a late arrival overwriting an edition built after it.
    func refreshAndPublish() async {
        guard !isRefreshing else {
            jdnLog("refresh: SKIPPED — one is already in flight")
            return
        }
        isRefreshing = true
        lastRefreshError = nil
        refreshStarted = Date()

        let work = Task { @MainActor [weak self] in await self?.performRefresh() }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await work.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.refreshTimeoutNanoseconds)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        isRefreshing = false
        if !finished {
            work.cancel()
            jdnLog("refresh: ABANDONED after \(Int(Self.refreshTimeout))s — it will not publish")
        }
    }

    /// How long a refresh is given before it is abandoned.
    ///
    /// Sized from the parts rather than picked. A refresh fetches every feed
    /// concurrently at a 20s per-feed timeout, and `fetchSelfHealing` can go
    /// round twice, so the fetch alone is worth 40s. Enrichment then fetches
    /// article pages at 10s each, and `validatedLeadEdition` will warm up to
    /// eight candidate lead images. That derives to roughly 90s of worst case.
    ///
    /// Measured against a real run on 2026-09-09: **254 feeds, 7,227 items,
    /// 415 enrichment candidates, 33.8 seconds end to end.** So this is about
    /// nine times the observed cost and three times the derived worst case.
    ///
    /// The first draft of this was 120s, chosen while assuming forty feeds. At
    /// 254 it would have left barely any headroom, and the cost of abandoning
    /// a refresh that was merely slow is losing an hour's news, which is the
    /// very fault this instrumentation exists to catch. The elapsed time is
    /// logged on every refresh so the margin can be checked rather than
    /// assumed a second time.
    private static let refreshTimeout: TimeInterval = 300
    private static let refreshTimeoutNanoseconds =
        UInt64(refreshTimeout * Double(NSEC_PER_SEC))

    private func performRefresh() async {
        // Paused feeds are held back from fetch; their cached items will be
        // stripped from the rebuilt edition via `applyPauseFilter` paths.
        let feeds = feedStore.feeds.filter { !$0.isPaused }
        let fetcher = self.fetcher
        let discovery = self.discovery

        // A sliding window, not one task per feed. 254 subscriptions meant 254
        // concurrent fetches at every refresh and at every launch, which is a
        // burst no desktop reader needs and the soft descriptor limit for a
        // GUI app on this machine is 256. See `concurrentFeedFetches`.
        let results = await withTaskGroup(of: (Feed, Result<FetchOutcome, Error>).self) { group in
            var next = feeds.makeIterator()
            var started = 0
            while started < Self.concurrentFeedFetches, let feed = next.next() {
                group.addTask {
                    await Self.fetchSelfHealing(feed, fetcher: fetcher, discovery: discovery)
                }
                started += 1
            }
            var acc: [(Feed, Result<FetchOutcome, Error>)] = []
            while let pair = await group.next() {
                acc.append(pair)
                if let feed = next.next() {
                    group.addTask {
                        await Self.fetchSelfHealing(feed, fetcher: fetcher, discovery: discovery)
                    }
                }
            }
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
                feedStore.recordFetchSuccess(feedId: feed.id)
            case .failure(let error):
                errors.append("\(feed.url.host ?? feed.url.absoluteString): \(error.localizedDescription)")
                feedStore.recordFetchFailure(feedId: feed.id)
            }
        }

        // Partial failure used to be invisible. `lastRefreshError` is only set
        // when *every* feed fails, so ten dead feeds out of forty looked
        // exactly like a healthy refresh, and a morning of them looked like a
        // quiet news day.
        let failed = errors.count
        jdnLog("refresh: \(feeds.count) feeds, \(feeds.count - failed) ok, "
               + "\(failed) failed, \(allItems.count) items")
        // One line each, not eight names crammed into the summary.
        //
        // The first version put them in the summary line and capped it at
        // eight. With 254 subscriptions and nineteen failures that hid eleven
        // of them, and answering "which ones?" meant fetching all 254 feeds by
        // hand outside the app. A log should not need a second tool.
        //
        // Sorted, because the fetches finish in whatever order the network
        // gives them and an unstable list cannot be compared with last hour's.
        for message in errors.sorted().prefix(Self.loggedFetchErrors) {
            jdnLog("refresh: feed failed — \(message)")
        }
        if failed > Self.loggedFetchErrors {
            jdnLog("refresh: feed failed — and \(failed - Self.loggedFetchErrors) more not listed")
        }

        // Carry over the previously-saved today edition so items accumulate
        // through the day. Feeds expose a rolling window of recent items; an
        // article published at 9am can rotate out of the feed's response by
        // noon, and without this merge it'd vanish from the paper even though
        // it was published today and was on page 1 an hour ago.
        //
        // Fresh items come first so the builder's first-seen-wins dedupe
        // prefers them over any staler copy in the prior edition (fresh may
        // have tightened summaries or newly-enriched image URLs). Removed
        // feeds are filtered out so deleting a feed still erases its items
        // from today's paper on the next refresh.
        if let existing = editionStore.today,
           Calendar.current.isDate(existing.date, inSameDayAs: Date()) {
            let activeFeedIds = Set(feedStore.feeds.map { $0.id })
            var priorItems: [FeedItem] = []
            if let lead = existing.lead { priorItems.append(lead) }
            priorItems.append(contentsOf: existing.secondaries)
            priorItems.append(contentsOf: existing.briefs)
            priorItems.append(contentsOf: existing.sections.flatMap { $0.items })
            let carried = priorItems.filter { activeFeedIds.contains($0.feedId) }
            allItems.append(contentsOf: carried)
            jdnLog("refresh: carried over \(carried.count) from the existing edition")
        } else if let existing = editionStore.today,
                  DayRollover.isDue(editionDate: existing.date,
                                    lastReset: lastDayRollover, now: Date()) {
            // A process left running across midnight reaches here once a day.
            // The enrichment memo is a record of which of *today's* items have
            // already been asked for a picture, so it is meaningless against a
            // new day's items and would otherwise grow for as long as the app
            // stays open.
            enrichmentAttempted.removeAll()
            enrichmentRetries.removeAll()
            // The picture caches are day-scoped for the same reason.
            ImageCache.shared.newDay()
            lastDayRollover = Date()
            jdnLog("refresh: new day — dropped the edition dated "
                   + "\(Self.dayFormatter.string(from: existing.date)) "
                   + "and cleared the enrichment memo")
        }

        // Enrich image-less candidates with og:image / twitter:image extracted
        // from the target article, so aggregator items (HN, DF, Tsai,
        // Objective-See) pick up a thumbnail from the real article page rather
        // than rendering text-only.
        //
        // The cap is PER SECTION, not per edition. A single edition-wide cap
        // starved the section pages: `EditionBuilder` takes the lead,
        // secondaries and briefs off the top of the date-sorted list, so the
        // front page's 16 slots consumed almost the whole allowance and the
        // sections got the un-enriched tail. Measured on 2026-09-05, the front
        // page had 9 of 16 items with images while the sections had 2 of 49.
        //
        // Cost: with N sections this admits up to N x 24 candidates instead of
        // 24. Only the image-LESS ones cost an HTTP fetch — `enrich` skips any
        // item whose feed already supplied a picture.
        // Bucket by the section the reader will actually SEE, not by
        // `item.section`. At this point that field still holds the raw feed
        // section — every item from a news feed says "News" — while the
        // section pages are stamped later in `recomputeVisibleEdition` from
        // the user's pins and the classifier. Bucketing on the raw field put
        // all 55 items in one bucket and the per-section cap did nothing.
        let sectionByFeed = Dictionary(uniqueKeysWithValues: feedStore.feeds.map { ($0.id, $0.section) })
        let sortedByDate = allItems.sorted { $0.publishedAt > $1.publishedAt }
        var takenPerSection: [String: Int] = [:]
        var topSlice: [FeedItem] = []
        var tail: [FeedItem] = []
        for item in sortedByDate {
            let section = resolvedSection(for: item, sectionByFeed: sectionByFeed)
            let taken = takenPerSection[section, default: 0]
            if taken < Self.enrichCapPerSection {
                takenPerSection[section] = taken + 1
                topSlice.append(item)
            } else {
                tail.append(item)
            }
        }
        jdnLog("refresh: enriching \(topSlice.count) of \(sortedByDate.count) "
               + "across \(takenPerSection.count) sections")
        enrichmentAttempted.formUnion(topSlice.map(\.itemId))
        let enrichment = await enricher.enrich(topSlice)
        // A page that would not fetch has told us nothing, so it must not be
        // written off for the day on one bad round trip — but it must not be
        // asked for ever either.
        allowRetry(of: enrichment.retryable)
        let enrichedSlice = enrichment.items
        // `builder.build` sorts by date before it dedupes, so this order no
        // longer decides which copy of a syndicated story survives. It did
        // once, silently: dedupe used to run first and keep whichever copy it
        // met, which put the choice at the mercy of fetch-completion order.
        let merged = enrichedSlice + tail

        var edition = builder.build(from: merged, date: Date())
        // Validate + warm the lead's image before publishing, so the hero
        // renders instantly and a slow/dead image never anchors the lead.
        edition = await validatedLeadEdition(edition, from: merged)
        // Don't blow away a populated cached edition when a refresh yields
        // nothing — the user is probably offline, or every feed 404'd. Keep
        // showing whatever we last had.
        let eligible = allItems.filter {
            EditionBuilder.dayRange(for: Date()).contains($0.publishedAt)
        }.count
        if edition.isEmpty, let existing = editionStore.today, !existing.isEmpty {
            // Naming the date matters more than the count. Keeping today's
            // edition when a refresh comes back empty is the intended
            // behaviour and usually means the network is down. Keeping
            // YESTERDAY's is a different thing entirely: just after midnight
            // nothing has been published yet, the rebuild is legitimately
            // empty, and this guard then holds yesterday's paper on screen,
            // which the app otherwise promises never to show. One line tells
            // the two apart.
            let kept = Self.dayFormatter.string(from: existing.date)
            let stale = !Calendar.current.isDateInToday(existing.date)
            jdnLog("refresh: rebuild was EMPTY of \(eligible) eligible — KEPT the "
                   + "\(stale ? "STALE " : "")edition dated \(kept), "
                   + "\(existing.itemCount) items")
            return
        }
        // An abandoned refresh must not publish. Without this, a slow one that
        // the watchdog gave up on could return minutes later and overwrite an
        // edition built after it, putting the paper backwards.
        if Task.isCancelled {
            jdnLog("refresh: abandoned before publishing — "
                   + "\(edition.itemCount) items discarded")
            return
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(refreshStarted))
        jdnLog("refresh: published \(edition.itemCount) items "
               + "of \(eligible) eligible from \(allItems.count) fetched "
               + "in \(elapsed)s of \(Int(Self.refreshTimeout))s allowed")
        let suppressed = edition.repeatedPictures.count
            + edition.sections.reduce(0) { $0 + $1.repeatedPictures.count }
        let withPictures = edition.sections.reduce(edition.secondaries.filter { $0.imageURL != nil }.count
            + edition.briefs.filter { $0.imageURL != nil }.count) {
                $0 + $1.items.filter { $0.imageURL != nil }.count
            }
        jdnLog("pictures: \(suppressed) of \(withPictures) suppressed as a repeat of one already "
               + "on the same page — \(PictureSignatureStore.shared.count) fingerprint(s) known")
        // Written once a refresh rather than on every decode: a full edition
        // decodes several hundred pictures and each write is the whole file.
        PictureSignatureStore.shared.flush()
        editionStore.save(edition)
        // Reflow the visible edition from the new base so hide-read and
        // paused filters apply to the freshly-built edition too.
        recomputeVisibleEdition()
        // Clamp page index if the new edition has fewer pages than we were on.
        if pageIndex >= totalPages { pageIndex = 0 }

        if allItems.isEmpty && !errors.isEmpty {
            lastRefreshError = errors.joined(separator: "\n")
        }
    }

    /// Ensure the built edition's lead has an image that actually loads within
    /// a reasonable time — warming the cache so it renders instantly. A slow
    /// or dead lead image is marked failed and the edition rebuilt, which
    /// re-picks the next usable-image item as lead (or drops the lead). The
    /// loop is bounded; in the common case the first lead validates on the
    /// first pass.
    private func validatedLeadEdition(_ edition: Edition, from items: [FeedItem]) async -> Edition {
        var current = edition
        var attempts = 0
        while attempts < 8, let img = current.lead?.imageURL {
            attempts += 1
            if await Self.validateImage(img) { break }      // lead image good — keep it
            // Bad/slow: validateImage marked it failed, so the rebuild skips it.
            current = builder.build(from: items, date: current.date)
        }
        return current
    }

    /// Load + warm the lead's image through the shared cache (coalesced with
    /// the on-screen view's fetch, so the URL is hit once). Returns whether it
    /// loaded — `image(for:)` caches it on success and records failure on
    /// timeout/error, which is exactly what the lead picker keys off.
    private nonisolated static func validateImage(_ url: URL) async -> Bool {
        await ImageCache.shared.image(for: url) != nil
    }

    func addFeed(url: URL, section: String) async {
        let feed = Feed(url: url, section: section.trimmingCharacters(in: .whitespaces))
        feedStore.add(feed)
        await refreshAndPublish()
    }

    /// Discover a feed from an arbitrary URL (feed URL or page URL), then add it.
    /// Returns the feed actually added so the caller can surface its title.
    /// Dedupes: if the resolved feed URL already exists in the store, throws
    /// `FeedDiscoveryError.alreadyAdded` naming the existing subscription.
    func discoverAndAdd(url: URL, section: String) async throws -> DiscoveredFeed {
        let candidates = try await discovery.discover(from: url)
        guard let first = candidates.first else { throw FeedDiscoveryError.noFeedsFound }

        let candidateKey = first.url.absoluteString.lowercased()
        if let existing = feedStore.feeds.first(where: {
            $0.url.absoluteString.lowercased() == candidateKey
        }) {
            let label = existing.title
                ?? first.title
                ?? existing.url.host
                ?? existing.url.absoluteString
            throw FeedDiscoveryError.alreadyAdded(existingTitle: label)
        }

        await addFeed(url: first.url, section: section)
        return first
    }

    func removeFeed(_ feed: Feed) async {
        feedStore.remove(feed)
        await refreshAndPublish()
    }

    /// Toggle pause for a feed. Pausing instantly reflows the visible
    /// edition (no network round-trip) by excluding that feed's items.
    /// Un-pausing triggers a full refresh so the feed's items come back.
    func togglePause(_ feed: Feed) async {
        let newPaused = !feed.isPaused
        feedStore.setPaused(feedId: feed.id, paused: newPaused)
        if newPaused {
            recomputeVisibleEdition()
        } else {
            await refreshAndPublish()
        }
    }

    /// Move a feed to a different section. Rebuilds the visible edition so
    /// the feed's existing cached items reappear under the new section
    /// immediately, with no network round-trip.
    func setSection(_ feed: Feed, to section: String) {
        feedStore.setSection(feedId: feed.id, section: section)
        recomputeVisibleEdition()
    }

    /// Move a single article to a different section. Pins the article
    /// permanently (future classifier guesses can't move it) and trains
    /// the classifier on this correction so similar future articles get
    /// the same treatment. Reflows the visible edition immediately.
    func moveArticle(_ item: FeedItem, to section: String) {
        let text = item.title + " " + item.summary
        classifier.move(itemId: item.itemId, text: text, to: section)
        recomputeVisibleEdition()
    }

    // MARK: - Excluded sources

    /// Normalised destination host for an item — lowercased, `www.` stripped.
    /// The unit the exclude list works in.
    static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// Display/host string for an item, or nil if its link has no host.
    func displayHost(for item: FeedItem) -> String? {
        Self.normalizedHost(item.link)
    }

    var excludedHostsSorted: [String] { excludedHosts.sorted() }

    /// Exclude an item's destination host from the paper and reflow. The
    /// aggregator feed that surfaced it keeps flowing — only items pointing
    /// at this host are dropped.
    func excludeSource(_ item: FeedItem) {
        guard let host = Self.normalizedHost(item.link) else { return }
        excludedHosts.insert(host)
        saveExcludedHosts()
        recomputeVisibleEdition()
    }

    /// Lift an exclusion (from the Manage Feeds sheet) and reflow.
    func includeSource(_ host: String) {
        guard excludedHosts.remove(host) != nil else { return }
        saveExcludedHosts()
        recomputeVisibleEdition()
    }

    private static func loadExcludedHosts() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedHosts") ?? [])
    }

    private func saveExcludedHosts() {
        UserDefaults.standard.set(Array(excludedHosts), forKey: "excludedHosts")
    }

    /// Union of every section name the paper currently knows about —
    /// those assigned to feeds plus those the classifier has been trained
    /// on. Used by the article and feed "Move to…" menus so the sections
    /// list stays consistent once the user has pinned articles into a
    /// section no feed belongs to.
    var allSections: [String] {
        var set = Set(feedStore.feeds.map { $0.section })
        set.formUnion(classifier.knownSections)
        return set.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Reflow the visible edition from the saved (unfiltered) base, applying
    /// the current pause + hide-read filters. Used whenever a filter changes
    /// or a fresh edition is saved. The on-disk edition is never a
    /// filtered view — only this in-memory representation is.
    func recomputeVisibleEdition() {
        guard let base = editionStore.today else {
            visibleEdition = nil
            return
        }

        var all: [FeedItem] = []
        if let lead = base.lead { all.append(lead) }
        all.append(contentsOf: base.secondaries)
        all.append(contentsOf: base.briefs)
        all.append(contentsOf: base.sections.flatMap { $0.items })

        let pausedIds = Set(feedStore.feeds.filter { $0.isPaused }.map { $0.id })
        var kept = all.filter { !pausedIds.contains($0.feedId) }
        if !excludedHosts.isEmpty {
            kept = kept.filter { item in
                guard let host = Self.normalizedHost(item.link) else { return true }
                return !excludedHosts.contains(host)
            }
        }
        if hideReadItems {
            kept = kept.filter { !readStore.isRead($0.itemId) }
        }
        // Re-stamp each item's section through three layers, in order:
        // 1. A user pin wins (explicit per-article correction, survives relaunch).
        // 2. Otherwise the classifier's confident prediction, if it has one.
        // 3. Otherwise the feed's current section (cold-start fallback).
        let sectionByFeed = Dictionary(uniqueKeysWithValues: feedStore.feeds.map { ($0.id, $0.section) })
        kept = kept.map { item in
            let resolved = resolvedSection(for: item, sectionByFeed: sectionByFeed)
            guard resolved != item.section else { return item }
            var updated = item
            updated.section = resolved
            return updated
        }

        visibleEdition = builder.build(from: kept, date: base.date)
        if pageIndex >= totalPages { pageIndex = 0 }
        topUpEnrichment(for: kept)
    }

    /// Fetch pictures for what the reader can still SEE, not for what the
    /// edition happens to contain.
    ///
    /// A refresh enriches the newest 24 per section of the WHOLE edition. With
    /// hide-read on, the visible paper is only the unread part of that, and it
    /// shrinks with every article opened — so the front page walks steadily
    /// into the tail that was never enriched and loses its pictures a few at a
    /// time. Running the same budget against the unread pool makes the cutoff
    /// follow the reader instead of the edition.
    ///
    /// The cap counts POSITION, exactly as the refresh does: the newest 24 of a
    /// section are eligible, and of those only the ones still missing a picture
    /// and not yet asked about are fetched. `enrichmentAttempted` is what stops
    /// this looping — the recompute at the end of `applyEnrichment` finds those
    /// items already asked about and produces no further work.
    private func topUpEnrichment(for kept: [FeedItem]) {
        guard !isToppingUp, !isRefreshing, !nextBatch(from: kept).isEmpty else { return }
        isToppingUp = true
        Task { [weak self] in
            guard let self else { return }
            // Carry the pool through the rounds. Nothing is being read while
            // this runs, so only the items' pictures change, not the set.
            var pool = kept
            var round = 0
            while round < Self.maxTopUpRounds {
                round += 1
                let batch = self.nextBatch(from: pool)
                guard !batch.isEmpty else { break }
                self.enrichmentAttempted.formUnion(batch.map(\.itemId))
                let enrichment = await self.enricher.enrich(batch)
                self.allowRetry(of: enrichment.retryable)
                let enriched = enrichment.items
                let found = Dictionary(uniqueKeysWithValues: enriched.map { ($0.itemId, $0) })
                pool = pool.map { found[$0.itemId] ?? $0 }
                self.applyEnrichment(enriched)
            }
            self.isToppingUp = false
        }
    }

    /// The next round of pages worth asking about: from each section still
    /// under the coverage target, the newest items that have no picture and
    /// have not been asked about, capped per section.
    /// Let a failed fetch be asked again, up to a limit, then leave it alone.
    private func allowRetry(of ids: Set<String>) {
        var spent = 0
        for id in ids {
            let used = enrichmentRetries[id, default: 0]
            guard used < Self.maxEnrichmentRetries else { spent += 1; continue }
            enrichmentRetries[id] = used + 1
            enrichmentAttempted.remove(id)
        }
        if spent > 0 {
            jdnLog("enrich: \(spent) page(s) have now failed to fetch "
                   + "\(Self.maxEnrichmentRetries + 1) times — not asking again today")
        }
    }

    private func nextBatch(from pool: [FeedItem]) -> [FeedItem] {
        let target = Self.imageCoverageTarget
        let sectionByFeed = Dictionary(uniqueKeysWithValues: feedStore.feeds.map { ($0.id, $0.section) })
        let bySection = Dictionary(grouping: pool) { resolvedSection(for: $0, sectionByFeed: sectionByFeed) }

        var batch: [FeedItem] = []
        for (_, items) in bySection {
            guard !items.isEmpty else { continue }
            let covered = items.filter { $0.imageURL != nil }.count
            guard Double(covered) / Double(items.count) < target else { continue }
            let candidates = items
                .filter { $0.imageURL == nil && !enrichmentAttempted.contains($0.itemId) }
                .sorted { $0.publishedAt > $1.publishedAt }
                .prefix(Self.topUpBatchPerSection)
            batch.append(contentsOf: candidates)
        }
        return batch
    }

    /// Fold newly-found pictures back into the saved edition and reflow.
    private func applyEnrichment(_ enriched: [FeedItem]) {
        guard let base = editionStore.today else { return }
        let found = Dictionary(uniqueKeysWithValues: enriched.map { ($0.itemId, $0) })

        var all: [FeedItem] = []
        if let lead = base.lead { all.append(lead) }
        all.append(contentsOf: base.secondaries)
        all.append(contentsOf: base.briefs)
        all.append(contentsOf: base.sections.flatMap { $0.items })

        var changed = false
        let updated = all.map { item -> FeedItem in
            guard let new = found[item.itemId],
                  new.imageURL != item.imageURL || new.summary != item.summary else { return item }
            changed = true
            return new
        }
        // Nothing found: the pages had no picture to give. The attempt is
        // already recorded, so this settles rather than repeating.
        guard changed else { return }

        editionStore.save(builder.build(from: updated, date: base.date))
        recomputeVisibleEdition()
    }

    private func resolvedSection(for item: FeedItem, sectionByFeed: [UUID: String]) -> String {
        if let pinned = classifier.pinnedSection(itemId: item.itemId) { return pinned }
        let text = item.title + " " + item.summary
        if let predicted = classifier.predict(text: text) { return predicted }
        return sectionByFeed[item.feedId] ?? item.section
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

    /// Whether two URLs are the same site for the purpose of self-healing.
    ///
    /// Host and scheme, compared exactly, except that an `http` feed is
    /// allowed to heal to `https` on the same host — an upgrade, and the one
    /// scheme change that is never a downgrade.
    private nonisolated static func sameHost(_ candidate: URL, as original: URL) -> Bool {
        guard let a = candidate.host?.lowercased(),
              let b = original.host?.lowercased(), a == b,
              let newScheme = candidate.scheme?.lowercased(),
              let oldScheme = original.scheme?.lowercased()
        else { return false }
        return newScheme == oldScheme || (oldScheme == "http" && newScheme == "https")
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
            // Self-healing follows a pointer the *served page* provides, and
            // the served page is whatever is at that address today. A feed
            // that stops parsing — because it was retired, sold, or taken over
            // — can answer with `<link rel="alternate" href="…">` naming any
            // address it likes, and `updateURL` below writes that into
            // `feeds.json` permanently. The user chose a subscription and
            // would silently have a different one.
            //
            // So healing may only move a feed WITHIN the host the user
            // subscribed to. That still covers what this was built for: a site
            // moving /feed to /rss, or handing out a new path. It does not
            // cover a site moving to a new domain, and it should not: that is
            // a decision for the person who chose the subscription.
            guard sameHost(found.url, as: feed.url) else {
                jdnLog("refresh: \(feed.url.host ?? "?") offered a feed at "
                       + "\(found.url.host ?? "?") — refused, a subscription may only "
                       + "move within its own host")
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
