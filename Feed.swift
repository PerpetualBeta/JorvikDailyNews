import Foundation

struct Feed: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var section: String
    var title: String?
    var lastSeenItemIds: [String]
    var isPaused: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        section: String,
        title: String? = nil,
        lastSeenItemIds: [String] = [],
        isPaused: Bool = false
    ) {
        self.id = id
        self.url = url
        self.section = section
        self.title = title
        self.lastSeenItemIds = lastSeenItemIds
        self.isPaused = isPaused
    }

    // Custom decoder so fields added in later versions (isPaused) default
    // cleanly when reading feeds.json from an older build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.url = try c.decode(URL.self, forKey: .url)
        self.section = try c.decode(String.self, forKey: .section)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.lastSeenItemIds = try c.decodeIfPresent([String].self, forKey: .lastSeenItemIds) ?? []
        self.isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
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
