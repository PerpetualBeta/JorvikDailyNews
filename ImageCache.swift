import AppKit

/// Process-wide cache of decoded hero images, keyed by source URL.
///
/// Without this, `OptionalImage` re-fetched and re-decoded on every page turn
/// or masonry re-layout — `.task(id:)` re-runs whenever the view is recreated,
/// so flipping pages re-downloaded every image and the content visibly
/// shuffled as each slot collapsed to its placeholder and then re-expanded.
///
/// Decoded `NSImage`s live in an `NSCache` (thread-safe, evicts under memory
/// pressure); URLs that resolved to a failure or a tracker-sized pixel are
/// remembered so we don't keep retrying them within the session. The whole
/// thing is intentionally in-memory and session-scoped: today's edition is
/// reflowed hourly, so there's nothing worth persisting to disk.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let images = NSCache<NSURL, NSImage>()
    private let lock = NSLock()
    private var failed = Set<URL>()

    init() {
        images.countLimit = 500
    }

    func image(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func store(_ image: NSImage, for url: URL) {
        images.setObject(image, forKey: url as NSURL)
    }

    func isFailed(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed.contains(url)
    }

    func markFailed(_ url: URL) {
        lock.lock(); failed.insert(url); lock.unlock()
    }
}
