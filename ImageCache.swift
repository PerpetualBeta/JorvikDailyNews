import AppKit
import Foundation

/// Process-wide cache + loader for hero images, keyed by source URL.
///
/// Two problems it solves:
///  1. **Re-downloading on every page turn.** `OptionalImage` recreates and
///     re-runs `.task` whenever a view is rebuilt; without a cache, flipping
///     pages re-fetched every image and the masonry reshuffled as slots
///     collapsed and re-expanded. Decoded images live in an `NSCache`
///     (evicts under memory pressure); `cachedImage(for:)` is a synchronous
///     peek so `OptionalImage.init` can render a hit on the first frame.
///  2. **Duplicate concurrent fetches.** The lead-image prefetch (see
///     `AppStore.validatedLeadEdition`) and the on-screen `OptionalImage`
///     would otherwise both hit the same URL at once — and some hosts (e.g.
///     GitHub's `opengraph.githubassets.com`) rate-limit the duplicate, so
///     one request fails and the view sticks on a broken hero even though the
///     other succeeded. `image(for:)` coalesces concurrent callers onto a
///     single in-flight `Task`, so a URL is fetched once and everyone shares
///     the result.
///
/// In-memory and session-scoped by design — today's edition reflows hourly,
/// so there's nothing worth persisting to disk.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let images = NSCache<NSURL, NSImage>()
    private let lock = NSLock()
    private var failed = Set<URL>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        images.countLimit = 500
    }

    /// Synchronous cache peek — for instant `@State` seeding in `OptionalImage.init`.
    func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func isFailed(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed.contains(url)
    }

    /// Load an image, coalescing concurrent requests for the same URL into a
    /// single download. Returns the cached image immediately on a hit, nil for
    /// a URL already known to have failed (sticky for the session), otherwise
    /// awaits the shared fetch. Success caches the image and clears any prior
    /// failed flag; failure (bad URL, non-2xx, undecodable, tracker-sized, or
    /// timeout) records it.
    func image(for url: URL, timeout: TimeInterval = 12) async -> NSImage? {
        if let img = images.object(forKey: url as NSURL) { return img }
        if isFailed(url) { return nil }
        return await sharedTask(for: url, timeout: timeout).value
    }

    private func sharedTask(for url: URL, timeout: TimeInterval) -> Task<NSImage?, Never> {
        lock.lock(); defer { lock.unlock() }
        if let existing = inFlight[url] { return existing }
        let task = Task<NSImage?, Never> { [weak self] in
            let image = await Self.download(url, timeout: timeout)
            self?.finish(url: url, image: image)
            return image
        }
        inFlight[url] = task
        return task
    }

    private func finish(url: URL, image: NSImage?) {
        lock.lock(); defer { lock.unlock() }
        inFlight[url] = nil
        if let image {
            images.setObject(image, forKey: url as NSURL)
            failed.remove(url)
        } else {
            failed.insert(url)
        }
    }

    private static func download(_ url: URL, timeout: TimeInterval) async -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        // Reject 1×1 trackers and icon-sized placeholders.
        guard let image = NSImage(data: data), image.size.width >= 48, image.size.height >= 48 else { return nil }
        return image
    }
}
