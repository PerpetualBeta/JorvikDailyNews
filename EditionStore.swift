import Foundation
import Observation

@Observable
@MainActor
final class EditionStore {
    private(set) var today: Edition?
    private let dir: URL

    /// How many days of edition files to keep on disk. The app is *Daily News*:
    /// only today's edition is ever read back (`loadToday`), so retention exists
    /// purely to stop the folder growing without bound. The window is deliberately
    /// generous rather than today-only — it costs a few hundred KB per day and
    /// gives a safety margin around the midnight boundary and any local-date
    /// string edge case. Tighten this to 1 for strict today-only.
    private static let retentionDays = 7

    init() {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = support.appendingPathComponent("JorvikDailyNews", isDirectory: true)
        self.dir = appDir.appendingPathComponent("editions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneOldEditions()
        loadToday()
    }

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func fileURL(for date: Date) -> URL {
        let name = Self.fileDateFormatter.string(from: date)
        return dir.appendingPathComponent("\(name).json")
    }

    func loadToday() {
        today = load(date: Date())
    }

    func load(date: Date) -> Edition? {
        let url = fileURL(for: date)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Edition.self, from: data)
    }

    func save(_ edition: Edition) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(edition) else { return }
        try? data.write(to: fileURL(for: edition.date), options: .atomic)
        if Calendar.current.isDateInToday(edition.date) {
            today = edition
        }
        // Sweep again after writing so a process left running across midnight
        // (which builds a new day's edition without ever re-launching) still
        // drops files that have aged out of the window.
        pruneOldEditions()
    }

    /// Delete edition files whose date is older than `retentionDays`. Keyed off
    /// the date encoded in the filename, not the file's modification time, so a
    /// re-saved old edition can't keep itself alive. Files whose names don't
    /// parse as a date are left untouched — we only delete what we recognise as
    /// ours.
    private func pruneOldEditions() {
        guard let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -(Self.retentionDays - 1),
            to: Calendar.current.startOfDay(for: Date())
        ) else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let date = Self.fileDateFormatter.date(from: stem) else { continue }
            if date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func hasTodayEdition() -> Bool {
        guard let today else { return false }
        return Calendar.current.isDateInToday(today.date)
    }
}
