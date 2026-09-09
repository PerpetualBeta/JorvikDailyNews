import Foundation

/// Remembers what each picture looks like, across launches.
///
/// It exists because of a timing problem. `PagePictures` has to decide which
/// cards keep their picture while the page is being built, and at that moment
/// most of the pictures have not been downloaded — they load as the reader
/// scrolls. Deciding later is not an option: a card that shows a photograph
/// and then loses it half a second afterwards is worse than the repetition it
/// was meant to fix.
///
/// So the fingerprint is written down the first time a picture is decoded and
/// read back on every later build. The honest consequence: **the very first
/// time a picture is seen, only its address is compared.** Repeats under one
/// URL (the arXiv logo) are caught immediately; the same photograph under
/// three different URLs is caught from the next refresh onwards, which in
/// practice is the next ten minutes.
final class PictureSignatureStore: @unchecked Sendable {
    static let shared = PictureSignatureStore()

    /// Enough for several days of a large paper. A signature is 116 bytes of
    /// payload, so the file stays under a megabyte at this size, and the cap
    /// exists to stop a long-running install growing one without limit.
    static let maxEntries = 6000

    private let lock = NSLock()
    private var signatures: [String: PictureSignature] = [:]
    /// Insertion order, so trimming drops the oldest rather than an arbitrary
    /// dictionary member.
    private var order: [String] = []
    private var dirty = false

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("JorvikDailyNews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("picture-signatures.json")
    }()

    private init() { load() }

    // MARK: - Reading

    func signature(for imageURL: URL) -> PictureSignature? {
        lock.lock(); defer { lock.unlock() }
        return signatures[imageURL.absoluteString]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return signatures.count
    }

    // MARK: - Writing

    func record(_ signature: PictureSignature, for imageURL: URL) {
        lock.lock(); defer { lock.unlock() }
        let key = imageURL.absoluteString
        if signatures[key] == nil { order.append(key) }
        signatures[key] = signature
        dirty = true
        if order.count > Self.maxEntries {
            let drop = order.prefix(order.count - Self.maxEntries)
            for k in drop { signatures[k] = nil }
            order.removeFirst(order.count - Self.maxEntries)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let stored = try? JSONDecoder().decode([String: PictureSignature].self, from: data)
        else {
            jdnLog("pictures: signature file unreadable — starting a new one")
            return
        }
        signatures = stored
        order = Array(stored.keys)
        jdnLog("pictures: \(stored.count) signature(s) loaded")
    }

    /// Written on a quit and at the end of a refresh rather than on every
    /// record, because a full edition decodes several hundred pictures and
    /// each write is the whole file.
    func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = signatures
        dirty = false
        lock.unlock()
        do {
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            jdnLog("pictures: could not write signatures — \(error.localizedDescription)")
        }
    }
}
