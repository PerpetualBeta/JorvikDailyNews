import Foundation
import Observation

/// Today's read marks in the order they were made, so Undo can take them back
/// one at a time.
///
/// `ReadStore` cannot answer this: it holds a set, with no order and no time,
/// and it keeps marks for ever so a story read yesterday stays read if it
/// resurfaces. This keeps only today's, newest last, in `read-history.json`
/// beside `read.json`. A mark from an earlier day is dropped when the file is
/// read, because the paper is day-scoped and bringing back a story from an
/// edition that is gone would bring back nothing.
@Observable
@MainActor
final class ReadHistory {
    struct Entry: Codable, Equatable {
        let itemId: String
        let at: Date
        /// The story was the front page's lead when it was read, so Undo puts
        /// it back there rather than into the columns.
        let wasLead: Bool
    }

    private(set) var entries: [Entry] = []
    private let storeURL: URL
    /// What "today" means, as a seam: a test fixes it rather than depending on
    /// the clock.
    private let now: () -> Date

    convenience init() {
        self.init(directory: ReadStore.supportDirectory())
    }

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("read-history.json")
        self.now = now
        load()
    }

    func record(_ itemId: String, wasLead: Bool) {
        dropEarlierDays()
        entries.append(Entry(itemId: itemId, at: now(), wasLead: wasLead))
        save()
    }

    /// Take the newest of today's marks off the list and hand it back.
    func popLatest() -> Entry? {
        dropEarlierDays()
        guard let last = entries.popLast() else { return nil }
        save()
        return last
    }

    var isEmpty: Bool {
        !entries.contains { Calendar.current.isDate($0.at, inSameDayAs: now()) }
    }

    private func dropEarlierDays() {
        let today = now()
        entries.removeAll { !Calendar.current.isDate($0.at, inSameDayAs: today) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = stored
        dropEarlierDays()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
