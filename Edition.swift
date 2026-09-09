import Foundation

struct Edition: Codable {
    let date: Date
    let publishedAt: Date
    let lead: FeedItem?
    let secondaries: [FeedItem]
    let briefs: [FeedItem]
    let sections: [SectionPage]

    var isEmpty: Bool {
        lead == nil && secondaries.isEmpty && briefs.isEmpty && sections.isEmpty
    }

    /// Every item the reader can reach, front page and section pages together.
    /// Exists so a refresh can say what it published without the caller having
    /// to know the shape of the paper.
    var itemCount: Int {
        (lead == nil ? 0 : 1) + secondaries.count + briefs.count
            + sections.reduce(0) { $0 + $1.items.count }
    }
}

struct SectionPage: Codable {
    let name: String
    let items: [FeedItem]
}
