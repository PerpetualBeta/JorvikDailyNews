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
}

struct SectionPage: Codable {
    let name: String
    let items: [FeedItem]
}
