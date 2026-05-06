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

    init(
        id: UUID = UUID(),
        url: URL,
        section: String,
        title: String? = nil,
        lastSeenItemIds: [String] = [],
        isPaused: Bool = false,
        lastSuccessfulFetchAt: Date? = nil,
        lastFailedFetchAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.section = section
        self.title = title
        self.lastSeenItemIds = lastSeenItemIds
        self.isPaused = isPaused
        self.lastSuccessfulFetchAt = lastSuccessfulFetchAt
        self.lastFailedFetchAt = lastFailedFetchAt
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
}
