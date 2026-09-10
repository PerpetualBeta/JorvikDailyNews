import CryptoKit
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

    /// The key a URL is filed under.
    ///
    /// A hash, not the address. The comment above used to reason that "a
    /// signature is 116 bytes of payload, so the file stays under a
    /// megabyte", and that is true of the *value*: the key was
    /// `absoluteString`, and the cap counts entries rather than bytes.
    ///
    /// A URL has no practical length limit here. Confirmed against a server
    /// accepting long request lines: `URLSession` sent request lines of 8,214,
    /// 65,558 and 200,022 bytes and every one returned 200, and
    /// `URL(string:)` accepted all of them. So 6,000 entries whose keys are
    /// 200 KB of query string is roughly 1.15 GB of JSON, rewritten atomically
    /// at the end of every refresh.
    ///
    /// 32 hex characters bounds the file by construction — 6,000 entries of
    /// about 180 bytes — and the semantics are unchanged, because the only
    /// operations here are exact-match get and set.
    private static func key(for imageURL: URL) -> String {
        let digest = SHA256.hash(data: Data(imageURL.absoluteString.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func signature(for imageURL: URL) -> PictureSignature? {
        lock.lock(); defer { lock.unlock() }
        return signatures[Self.key(for: imageURL)]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return signatures.count
    }

    // MARK: - Writing

    func record(_ signature: PictureSignature, for imageURL: URL) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(for: imageURL)
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
        // Sorted, not `Array(stored.keys)`.
        //
        // Dictionary order is arbitrary and differs between launches, so the
        // trim below evicted an arbitrary entry rather than the oldest, and
        // did it differently every time. A sort is not the true insertion
        // order — that is not recorded — but it is at least stable, so
        // eviction is repeatable and a warm store stays warm.
        order = stored.keys.sorted()
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
