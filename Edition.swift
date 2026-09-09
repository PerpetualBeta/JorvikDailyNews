import Foundation

struct Edition: Codable {
    let date: Date
    let publishedAt: Date
    let lead: FeedItem?
    let secondaries: [FeedItem]
    let briefs: [FeedItem]
    let sections: [SectionPage]

    /// Item ids on the front page whose picture repeats one already used
    /// there. See `PagePictures`.
    ///
    /// Held on the page rather than on the item, and that distinction matters.
    /// A refresh carries items forward from the saved edition but rebuilds
    /// every page, so a decision stored on an item would follow it to a page
    /// where it was never a repeat and cost it a picture for good. Stored
    /// here, the decision is recomputed with the page it belongs to.
    let repeatedPictures: Set<String>

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

    init(date: Date, publishedAt: Date, lead: FeedItem?, secondaries: [FeedItem],
         briefs: [FeedItem], sections: [SectionPage], repeatedPictures: Set<String> = []) {
        self.date = date
        self.publishedAt = publishedAt
        self.lead = lead
        self.secondaries = secondaries
        self.briefs = briefs
        self.sections = sections
        self.repeatedPictures = repeatedPictures
    }

    /// Written by hand only so that an edition saved before this field existed
    /// still loads. Everything else is the synthesised behaviour.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        publishedAt = try c.decode(Date.self, forKey: .publishedAt)
        lead = try c.decodeIfPresent(FeedItem.self, forKey: .lead)
        secondaries = try c.decode([FeedItem].self, forKey: .secondaries)
        briefs = try c.decode([FeedItem].self, forKey: .briefs)
        sections = try c.decode([SectionPage].self, forKey: .sections)
        repeatedPictures = try c.decodeIfPresent(Set<String>.self, forKey: .repeatedPictures) ?? []
    }
}

struct SectionPage: Codable {
    let name: String
    let items: [FeedItem]

    /// Item ids on this page whose picture repeats one already used on it.
    let repeatedPictures: Set<String>

    init(name: String, items: [FeedItem], repeatedPictures: Set<String> = []) {
        self.name = name
        self.items = items
        self.repeatedPictures = repeatedPictures
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        items = try c.decode([FeedItem].self, forKey: .items)
        repeatedPictures = try c.decodeIfPresent(Set<String>.self, forKey: .repeatedPictures) ?? []
    }
}
