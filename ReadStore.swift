import Foundation
import Observation

/// Tracks which article itemIds the user has opened (clicked through to the
/// reader). Read state is a lightweight visual affordance only — no counts,
/// no badges, no filtering. The list persists across sessions so a
/// yesterday-read item stays marked if it resurfaces.
@Observable
@MainActor
final class ReadStore {
    private(set) var readIds: Set<String> = []
    private let storeURL: URL

    init() {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("JorvikDailyNews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("read.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let ids = try? JSONDecoder().decode([String].self, from: data) {
            readIds = Set(ids)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(readIds)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    func markRead(_ itemId: String) {
        guard !readIds.contains(itemId) else { return }
        readIds.insert(itemId)
        save()
    }

    func markUnread(_ itemId: String) {
        guard readIds.contains(itemId) else { return }
        readIds.remove(itemId)
        save()
    }

    func isRead(_ itemId: String) -> Bool {
        readIds.contains(itemId)
    }

    func clearAll() {
        readIds = []
        save()
    }
}
