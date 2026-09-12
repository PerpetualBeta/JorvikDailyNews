import Foundation

struct Feed: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var section: String
    var title: String?
    var lastSeenItemIds: [String]
    var isPaused: Bool

    /// Timestamp of the most recent fetch that returned a parseable feed.
    /// Nil means we've never had a successful fetch (brand-new feed, or
    /// always-failing URL). Drives the green/amber/red status pill.
    var lastSuccessfulFetchAt: Date?

    /// Timestamp of the most recent fetch that errored. Nil means the most
    /// recent attempt succeeded (or there's been no attempt at all).
    var lastFailedFetchAt: Date?

    /// The publication date of the newest item this feed offered, as of its
    /// last successful fetch.
    ///
    /// Nil means either that no successful fetch has recorded one yet, or that
    /// the feed dates nothing it publishes. `FeedFetcher` gives an undated
    /// item `Date.distantPast`, so a feed carrying no dates at all would
    /// otherwise read as infinitely old. Those are recorded as nil instead,
    /// and a feed that never offers a date is never called dormant.
    var newestItemAt: Date?

    /// The site this feed says it belongs to, from its channel `<link>`.
    ///
    /// Not the feed's own address: that opens as a page of XML. Recorded so
    /// the manage-feeds sheet can offer to open the site, which is what
    /// deciding whether to keep a subscription actually needs.
    var siteURL: URL?

    /// When the paper last said out loud that this feed had gone dormant.
    ///
    /// **A standing count would be a nag, and this app has none.** Measured
    /// by the app itself on 2026-09-12, across 238 active feeds of which 222
    /// had a publication date to read: **89 of them, 40 per cent, had
    /// published nothing for over a year**, 72 of those nothing for over two,
    /// and the oldest nothing since 2005-12-09. A line naming that every
    /// morning is not a printer's note, it is an accusation that never goes
    /// away and that only pruning 89 subscriptions could silence.
    ///
    /// So each feed is mentioned once, as it crosses the line, and the
    /// manage-feeds sheet holds the standing truth for whenever housekeeping
    /// is actually wanted. Cleared again if the feed starts publishing, so a
    /// second dormancy is reported like the first.
    var dormancyAnnouncedAt: Date?

    init(
        id: UUID = UUID(),
        url: URL,
        section: String,
        title: String? = nil,
        lastSeenItemIds: [String] = [],
        isPaused: Bool = false,
        lastSuccessfulFetchAt: Date? = nil,
        lastFailedFetchAt: Date? = nil,
        newestItemAt: Date? = nil,
        dormancyAnnouncedAt: Date? = nil,
        siteURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.section = section
        self.title = title
        self.lastSeenItemIds = lastSeenItemIds
        self.isPaused = isPaused
        self.lastSuccessfulFetchAt = lastSuccessfulFetchAt
        self.lastFailedFetchAt = lastFailedFetchAt
        self.newestItemAt = newestItemAt
        self.dormancyAnnouncedAt = dormancyAnnouncedAt
        self.siteURL = siteURL
    }

    // Custom decoder so fields added in later versions default cleanly when
    // reading feeds.json from an older build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.url = try c.decode(URL.self, forKey: .url)
        self.section = try c.decode(String.self, forKey: .section)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.lastSeenItemIds = try c.decodeIfPresent([String].self, forKey: .lastSeenItemIds) ?? []
        self.isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        self.lastSuccessfulFetchAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulFetchAt)
        self.lastFailedFetchAt = try c.decodeIfPresent(Date.self, forKey: .lastFailedFetchAt)
        self.newestItemAt = try c.decodeIfPresent(Date.self, forKey: .newestItemAt)
        self.dormancyAnnouncedAt = try c.decodeIfPresent(Date.self, forKey: .dormancyAnnouncedAt)
        self.siteURL = try c.decodeIfPresent(URL.self, forKey: .siteURL)
    }
}

extension Feed {
    enum FetchStatus {
        /// Most recent attempt was a success — or there's been no attempt
        /// yet (brand-new feed). Treated as healthy by default.
        case healthy
        /// Most recent attempt failed, but a successful fetch landed within
        /// the last 30 days. Probably transient.
        case recent
        /// Failing for more than 30 days, or never succeeded. Likely dead.
        case stale
    }

    /// How long a feed may be failing before the paper says so.
    ///
    /// A day, so an overnight outage at one publisher is not an announcement
    /// and a feed that has genuinely stopped is.
    static let silentFailureThreshold: TimeInterval = 24 * 60 * 60

    /// Whether this feed has been failing long enough to be worth telling the
    /// reader about.
    ///
    /// **The data for this already existed and nothing looked at it.** Nine
    /// plain-http feeds failed on every hourly refresh for a day after an
    /// Info.plist change, and the only trace was one log line per feed per
    /// attempt, in a log that is off by default. The manage-feeds sheet showed
    /// them as red dots the whole time, which helps nobody who has no reason
    /// to open it.
    ///
    /// Never true for a feed that has simply not been tried yet, and never
    /// true for one whose last attempt succeeded.
    func isSilentlyFailing(asOf now: Date = Date()) -> Bool {
        guard let failed = lastFailedFetchAt else { return false }
        if let succeeded = lastSuccessfulFetchAt, succeeded >= failed { return false }
        let since = lastSuccessfulFetchAt ?? failed
        return now.timeIntervalSince(since) >= Feed.silentFailureThreshold
    }

    /// How long a feed may publish nothing before the paper mentions it.
    ///
    /// A year, which is Jonathan's number. Anything shorter names a personal
    /// blog between posts; anything longer stops being useful for the job this
    /// is for, which is knowing what to prune.
    static let dormancyThreshold: TimeInterval = 365 * 24 * 60 * 60

    /// Whether this feed answers normally and publishes nothing.
    ///
    /// **Not the same as `FetchStatus.stale`, which is the opposite problem.**
    /// That one means the feed cannot be reached at all. This one is
    /// reachable, parses, returns items, and has simply stopped — the state
    /// nothing in the app could see, because every health signal it had was
    /// about the fetch rather than about the contents.
    ///
    /// Never true for a feed that is already being reported as unreachable:
    /// two notices about one feed is two faults where there is one.
    func isDormant(asOf now: Date = Date()) -> Bool {
        guard !isPaused else { return false }
        guard let newest = newestItemAt else { return false }
        guard !isSilentlyFailing(asOf: now) else { return false }
        return now.timeIntervalSince(newest) >= Feed.dormancyThreshold
    }

    /// Where to send somebody who wants to look at this feed's site.
    ///
    /// The channel link when the feed offered one, and the feed's own host
    /// otherwise — never the feed URL itself, which opens as XML. Nil only
    /// when neither can be made into a web address, in which case the sheet
    /// offers nothing rather than an address that goes nowhere.
    var reviewURL: URL? {
        if let siteURL, WebURL.isAllowed(siteURL) { return siteURL }
        guard let host = url.host, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return URL(string: "\(scheme)://\(host)/")
    }

    /// Fold a successful fetch into this feed's record.
    ///
    /// Here rather than in `FeedStore` so the suite can read it without a
    /// store, and therefore without a real `feeds.json` to write into.
    mutating func recordSuccess(newestItemAt newest: Date?, siteLink: String? = nil,
                                at date: Date) {
        lastSuccessfulFetchAt = date
        // Only a web address, and only one the app would be willing to fetch.
        // A feed's channel link is a string the feed chooses.
        if let siteLink, let candidate = URL(string: siteLink), WebURL.isAllowed(candidate) {
            siteURL = candidate
        }
        lastFailedFetchAt = nil
        // Passing nil leaves any previously recorded date alone rather than
        // erasing it: "this fetch carried no dates" is not evidence that the
        // last one carried none either.
        if let newest { newestItemAt = newest }
        // A feed that has started publishing again gets its mention back, so
        // that a second dormancy is reported like the first.
        if dormancyAnnouncedAt != nil, !isDormant(asOf: date) { dormancyAnnouncedAt = nil }
    }

    /// Dormant, and the reader has not been told yet.
    func isUnannouncedDormant(asOf now: Date = Date()) -> Bool {
        dormancyAnnouncedAt == nil && isDormant(asOf: now)
    }

    /// Three-state health summary for the manage-feeds pill.
    /// Boundary between `recent` and `stale` is 30 days since last success.
    var fetchStatus: FetchStatus {
        let mostRecentIsFailure: Bool
        switch (lastSuccessfulFetchAt, lastFailedFetchAt) {
        case (nil, nil): return .healthy   // never tried — give it benefit of the doubt
        case (_, nil): mostRecentIsFailure = false
        case (nil, _): mostRecentIsFailure = true
        case let (s?, f?): mostRecentIsFailure = f > s
        }
        if !mostRecentIsFailure { return .healthy }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        if let s = lastSuccessfulFetchAt, s > cutoff { return .recent }
        return .stale
    }
}

struct FeedItem: Codable, Hashable, Identifiable {
    var id: String { itemId }
    let feedId: UUID
    let itemId: String
    let title: String
    let link: URL
    let summary: String
    let imageURL: URL?
    let publishedAt: Date
    var section: String
    let sourceTitle: String

    /// The identity this item had before identities were namespaced by feed.
    ///
    /// Carried only so read marks and pins survive the change. Optional
    /// because an edition saved by an older build has no such field, and
    /// nil-safe everywhere it is used. Removable once nobody is upgrading
    /// across this version.
    var legacyItemId: String?

    /// The host of the subscription this item came from.
    ///
    /// The one string on a `FeedItem` a feed cannot choose: it is taken from
    /// the URL the reader subscribed to, not from anything in the XML. Carried
    /// because `EditionBuilder.publishesItsOwn` needs to compare a link's host
    /// against the host that offered it, and `feedId` alone cannot say what
    /// that was. Optional for editions saved before this field existed; the
    /// comparison simply declines to prefer when it is nil.
    var feedHost: String?

    /// Title as shown in the paper, with a " [VIDEO]" affordance appended when
    /// the link plays in-app as a video (YouTube / Vimeo / direct media) and
    /// nothing in the title or summary already signals that. Computed at
    /// display time rather than baked into `title`, so it applies uniformly to
    /// every item — freshly fetched, carried over from an earlier refresh, or
    /// loaded from a previously-saved edition — without depending on when the
    /// item was parsed. Most video feeds label their own items; this catches
    /// the few submitters who don't, so you're never sent to a video unawares.
    var displayTitle: String {
        guard VideoLink.detect(link) != nil else { return title }
        let haystack = (title + " " + summary).lowercased()
        let alreadyFlagged = ["video", "watch", "▶", "📺", "🎥", "🎬"]
            .contains { haystack.contains($0) }
        return alreadyFlagged ? title : title + " [VIDEO]"
    }
}

extension FeedItem {
    /// Legacy identities exactly one item in this edition claims.
    ///
    /// A guid is printed in a feed's own public XML, so two items offering the
    /// same one means somebody copied it. Awarding such a key by position
    /// handed it to whichever feed sorted first, and the sort is on a date the
    /// feed writes.
    static func uncontestedLegacyKeys(in items: [FeedItem]) -> Set<String> {
        var claimants: [String: Int] = [:]
        for item in items {
            guard let legacy = item.legacyItemId, legacy != item.itemId else { continue }
            claimants[legacy, default: 0] += 1
        }
        return Set(claimants.filter { $0.value == 1 }.keys)
    }
}

extension Array where Element == Feed {

    /// What the paper says when these feeds have quietly stopped working.
    ///
    /// Here rather than in the view so the suite can read it. The wording
    /// agrees with the count in two places — the sentence and the action — and
    /// getting one of them wrong is the sort of thing that survives a build,
    /// a test run and a review, because it only looks wrong to a person.
    var silentFailureSentence: String {
        sentence(singular: "has not been reachable for over a day",
                 plural: "have not been reachable for over a day")
    }

    /// What the paper says when these feeds are answering and publishing
    /// nothing.
    var dormantSentence: String {
        sentence(singular: "has published nothing for over a year",
                 plural: "have published nothing for over a year")
    }

    /// Names them while there are few enough to read, counts them after that.
    ///
    /// Four or more is a list, and a list belongs in the manage-feeds sheet
    /// rather than under a dateline. The dormancy case reaches that branch
    /// immediately on a real subscription list — 89 of 238 feeds here — which
    /// is why the count form has to read as well as the names do.
    private func sentence(singular: String, plural: String) -> String {
        let names = compactMap { $0.title ?? $0.url.host }
        switch count {
        case 0:
            return ""
        case 1:
            return "\(names.first ?? "One feed") \(singular)."
        case 2, 3:
            return "\(names.joined(separator: ", ")) \(plural)."
        default:
            return "\(count) feeds \(plural)."
        }
    }

    /// The action beside it, which has to agree with the sentence.
    var silentFailureAction: String {
        count == 1 ? "Review it" : "Review them"
    }
}
