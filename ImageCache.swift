import AppKit
import Foundation
import Vision

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

/// Where the eye goes in a picture, so an over-tall picture is cropped around
/// its subject instead of blindly from the top.
///
/// Uses Vision's attention-based saliency (the technique in Apple's "Cropping
/// Images Using Saliency"): it returns the region a person would look at
/// first. We keep only the centre point of that region, normalised, because
/// the crop window's size is decided by the layout, not by Vision.
///
/// Results are cached per URL for the session. A picture with no salient
/// region — a flat illustration, a site icon, a solid colour — yields nil, and
/// the caller falls back to the old top-aligned crop.
final class SaliencyCache: @unchecked Sendable {
    static let shared = SaliencyCache()

    private let lock = NSLock()
    /// Normalised centre in VISION coordinates: origin bottom-left, so y = 1
    /// is the top of the picture. Cached as `.some(nil)` when Vision ran and
    /// found nothing, so we don't run it twice.
    private var centres: [URL: CGPoint?] = [:]

    /// Vertical centre of the salient region, normalised, Vision coordinates.
    /// Runs Vision at most once per URL; subsequent calls return the cache.
    func centreY(for url: URL, image: NSImage) async -> CGFloat? {
        if let hit = cached(url) { return hit?.y }
        let centre = await Task.detached(priority: .utility) {
            Self.salientCentre(of: image)
        }.value
        store(centre, for: url)
        return centre?.y
    }

    // The lock is taken and released inside these two, never across the `await`
    // above: NSLock is not safe to hold over a suspension point.

    /// Doubly optional on purpose: the outer layer is "have we run Vision on
    /// this URL", the inner is "did Vision find anything".
    private func cached(_ url: URL) -> CGPoint?? {
        lock.lock(); defer { lock.unlock() }
        return centres[url]
    }

    private func store(_ centre: CGPoint?, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        centres[url] = centre
    }

    private static func salientCentre(of image: NSImage) -> CGPoint? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let objects = observation.salientObjects,
              !objects.isEmpty
        else { return nil }

        // Union of every salient box, so a picture with two subjects crops to
        // include both rather than centring on whichever Vision listed first.
        let union = objects.dropFirst().reduce(objects[0].boundingBox) { $0.union($1.boundingBox) }
        return CGPoint(x: union.midX, y: union.midY)
    }
}
