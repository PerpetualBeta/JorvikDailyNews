import Foundation
import Observation

@Observable
@MainActor
final class EditionStore {
    private(set) var today: Edition?
    private let dir: URL

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
    }

    func hasTodayEdition() -> Bool {
        guard let today else { return false }
        return Calendar.current.isDateInToday(today.date)
    }
}
