import AppKit
import Foundation
import ImageIO
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
/// In-memory and session-scoped by design: today's edition reflows hourly,
/// so there's nothing worth persisting to disk. Nothing here writes a file,
/// which is why there is no picture cache to clean up between days.
///
/// Memory is bounded two ways, and both are needed. Pictures are decoded
/// scaled down (`decode`), so a 6000 px CDN original never becomes a 144 MB
/// bitmap; and the cache is capped in BYTES as well as in count, because
/// `countLimit` alone says nothing about size.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let images = NSCache<NSURL, NSImage>()
    private let lock = NSLock()
    /// URLs that will never work: gone, undecodable, or a tracking pixel.
    /// Remembered for the session, because asking again cannot change the
    /// answer.
    private var failed = Set<URL>()
    /// URLs whose last attempt failed for a reason that MIGHT change, and the
    /// moment it becomes worth trying again.
    private var retryAfter: [URL: Date] = [:]
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    /// Whether pictures are loaded at all.
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews showPictures -bool NO
    ///     defaults delete cc.jorviksoftware.JorvikDailyNews showPictures
    ///
    /// Off, nothing is downloaded and Vision never runs, so the paper costs
    /// little more than its text. Two uses: a Mac short of memory, and
    /// isolating a fault. If a symptom survives with pictures off, pictures
    /// are not what is causing it.
    ///
    /// Read through `object(forKey:)` rather than `bool(forKey:)`, which
    /// answers false for a key that was never set and would ship the app with
    /// pictures off.
    ///
    /// Gated in this class rather than in the views because it is the one
    /// choke point all eight call sites pass through, `EditionBuilder
    /// .hasUsableImage` among them. That last one matters: reporting every URL
    /// as failed is what makes lead selection fall through to a text lead,
    /// instead of anchoring the front page on a picture that will never come.
    static let picturesKey = "showPictures"

    static var picturesEnabled: Bool {
        UserDefaults.standard.object(forKey: picturesKey) as? Bool ?? true
    }

    /// Longest edge, in pixels, a picture is kept at.
    ///
    /// Derived from the widest one is ever drawn: `Paper.maxWidth` (1100) less
    /// `Paper.horizontalPadding` on each side (48 × 2) is 1004 points, so 2048
    /// covers a full-width lead on a 2× display with room over. Above that is
    /// detail no window in JDN can show, and it is not free.
    static let maxPixelSizeDefault = 2048
    static let maxPixelSizeKey = "imageMaxPixelSize"

    static var maxPixelSize: Int {
        let stored = UserDefaults.standard.integer(forKey: maxPixelSizeKey)
        return stored > 0 ? stored : maxPixelSizeDefault
    }

    /// Bytes of decoded picture worth keeping.
    ///
    /// A share of physical memory, not a fixed number, because the right
    /// answer on an 8 GB Mac is not the right answer on a 64 GB one: a
    /// thirty-second gives 256 MB and 2 GB respectively.
    static let cacheByteLimit: Int = {
        Int(ProcessInfo.processInfo.physicalMemory / 32)
    }()

    /// How long to leave a transient failure alone before trying again.
    ///
    /// Long enough that a dead host is not hammered by every view rebuild —
    /// `OptionalImage` re-runs its load task whenever the masonry reflows —
    /// and short enough that a paper blanked by a moment of throttling repairs
    /// itself on the next refresh rather than needing a relaunch.
    static let transientCooloffDefault: TimeInterval = 60
    static let cooloffKey = "imageRetryCooloffSeconds"

    static var transientCooloff: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: cooloffKey)
        return stored > 0 ? stored : transientCooloffDefault
    }

    /// Why a download did not produce an image.
    ///
    /// The distinction is the whole point. Treating every failure as permanent
    /// meant one burst of throttling — a refresh firing dozens of concurrent
    /// requests at the same handful of CDNs — blanked every picture in the
    /// paper until the app was quit, and took the lead with it, because
    /// `EditionBuilder.hasUsableImage` consults the same set.
    private enum Outcome {
        case image(NSImage)
        /// The URL is bad and will stay bad.
        case permanent
        /// The request failed; the URL may be fine.
        case transient
    }

    init() {
        // Both limits, deliberately. `countLimit` bounds how many pictures are
        // held; only `totalCostLimit` bounds how much memory they take, and it
        // is the second that decides whether a 24-story front page fits on a
        // small machine. 500 full-resolution heroes could be several GB.
        images.countLimit = 500
        images.totalCostLimit = Self.cacheByteLimit
    }

    /// Synchronous cache peek — for instant `@State` seeding in `OptionalImage.init`.
    func cachedImage(for url: URL) -> NSImage? {
        guard Self.picturesEnabled else { return nil }
        return images.object(forKey: url as NSURL)
    }

    /// Whether a URL is not worth showing right now — permanently bad, or
    /// transiently failed and still inside its cool-off. Lead selection asks
    /// this too, so a picture in cool-off cannot anchor the front page.
    func isFailed(_ url: URL) -> Bool {
        // With pictures off every URL is unusable, which is the answer lead
        // selection needs to pick a text lead rather than a blank hero.
        guard Self.picturesEnabled else { return true }
        lock.lock(); defer { lock.unlock() }
        if failed.contains(url) { return true }
        if let until = retryAfter[url] { return Date() < until }
        return false
    }

    /// Load an image, coalescing concurrent requests for the same URL into a
    /// single download. Returns the cached image immediately on a hit, nil for
    /// a URL already known to have failed (sticky for the session), otherwise
    /// awaits the shared fetch. Success caches the image and clears any prior
    /// failed flag; failure (bad URL, non-2xx, undecodable, tracker-sized, or
    /// timeout) records it.
    func image(for url: URL, timeout: TimeInterval = 12) async -> NSImage? {
        guard Self.picturesEnabled else { return nil }
        if let img = images.object(forKey: url as NSURL) { return img }
        if isFailed(url) { return nil }
        return await sharedTask(for: url, timeout: timeout).value
    }

    private func sharedTask(for url: URL, timeout: TimeInterval) -> Task<NSImage?, Never> {
        lock.lock(); defer { lock.unlock() }
        if let existing = inFlight[url] { return existing }
        let task = Task<NSImage?, Never> { [weak self] in
            let outcome = await Self.download(url, timeout: timeout)
            self?.finish(url: url, outcome: outcome)
            if case .image(let image) = outcome { return image }
            return nil
        }
        inFlight[url] = task
        return task
    }

    private func finish(url: URL, outcome: Outcome) {
        lock.lock(); defer { lock.unlock() }
        inFlight[url] = nil
        switch outcome {
        case .image(let image):
            images.setObject(image, forKey: url as NSURL, cost: Self.byteCost(of: image))
            failed.remove(url)
            retryAfter[url] = nil
        case .permanent:
            failed.insert(url)
            retryAfter[url] = nil
        case .transient:
            retryAfter[url] = Date().addingTimeInterval(Self.transientCooloff)
        }
    }

    private static func download(_ url: URL, timeout: TimeInterval) async -> Outcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // A timeout, a dropped connection, a DNS hiccup. Nothing here says
            // the picture is bad.
            return .transient
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 5xx is the server having a bad day, 429 is us asking too fast and
            // 408 is a timeout by another name. All three are worth retrying.
            // Everything else — 404, 410, 403 — is an answer, not an accident.
            let retryable = http.statusCode >= 500 || http.statusCode == 429 || http.statusCode == 408
            return retryable ? .transient : .permanent
        }

        // Reject 1×1 trackers and icon-sized placeholders. Undecodable bytes and
        // a tracking pixel are both settled facts about the URL.
        guard let image = decode(data), image.size.width >= 48, image.size.height >= 48 else {
            return .permanent
        }
        return .image(image)
    }

    /// Decode a picture at no more than `maxPixelSize` on its long edge.
    ///
    /// `NSImage(data:)` decodes at the source's own resolution and holds it,
    /// so a front page of 24 stories cost whatever those 24 originals happened
    /// to be. ImageIO scales during decode instead, so the full-size bitmap is
    /// never allocated at all. An og:image is usually 1200 × 630, which passes
    /// through untouched; a CDN original can be 6000 px wide, which as a
    /// bitmap is about 144 MB.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` applies the EXIF
    /// orientation. Without it a picture taken in portrait comes back on its
    /// side, because the flag that says so is in metadata this path discards.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` ignores any thumbnail
    /// already embedded in the file, which is typically 160 px and would look
    /// like a badly blurred hero.
    private static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        // Size in pixels, so `NSImage.size` and the bitmap agree. The 48pt
        // tracker threshold above is a pixel test in intent, and this is what
        // makes it one.
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// What a decoded picture costs the cache, in bytes: four per pixel.
    ///
    /// `NSCache` cost is in whatever unit you supply, so supplying bytes is
    /// what makes `totalCostLimit` a memory limit rather than a number.
    private static func byteCost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1 }
        return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
    }
}

/// Where the subject is in a picture, so an over-tall picture is cropped around
/// it instead of blindly from the top.
///
/// **Faces first.** Vision's attention-based saliency answers "what is visually
/// loudest", which on a photograph of a person is the teeth and the collar
/// line, not the head. Centring the crop on that answer cut the top of a
/// subject's head off. `VNDetectFaceRectanglesRequest` answers the question we
/// are actually asking, so it runs first; attention saliency is the fallback
/// for pictures with nobody in them.
///
/// Returns a vertical SPAN rather than a centre point. A centre cannot express
/// "the subject is taller than the window you have", and that case has a right
/// answer: keep the top. Losing a chin beats losing a crown.
///
/// Results are cached per URL for the session. A picture with no subject at all
/// — a flat illustration, a site icon, a solid colour — yields nil, and the
/// caller falls back to the top-aligned crop.
final class SaliencyCache: @unchecked Sendable {
    static let shared = SaliencyCache()

    /// The subject's vertical extent, normalised as distance DOWN from the top
    /// of the picture, so the caller never has to flip Vision's bottom-left
    /// coordinates itself.
    struct Span: Sendable, Equatable {
        let top: CGFloat
        let bottom: CGFloat
        var height: CGFloat { bottom - top }
        var centre: CGFloat { (top + bottom) / 2 }
    }

    /// How much of a head sits above the box Vision draws round a face.
    ///
    /// `VNDetectFaceRectanglesRequest` bounds the face itself, roughly chin to
    /// upper forehead. The crown and the hair sit above that, and they are what
    /// got cut off. A whole head runs about a third taller than the detected
    /// box, so the span is extended upward by that much before the crop is
    /// placed. Live knob: `defaults write cc.jorviksoftware.JorvikDailyNews
    /// faceCrownAllowance -float 0.5`.
    static let crownAllowanceDefault: CGFloat = 0.35
    static let crownAllowanceKey = "faceCrownAllowance"

    static var crownAllowance: CGFloat {
        let stored = UserDefaults.standard.double(forKey: crownAllowanceKey)
        return stored > 0 ? CGFloat(stored) : crownAllowanceDefault
    }

    private let lock = NSLock()
    /// Cached as `.some(nil)` when Vision ran and found nothing, so it does not
    /// run twice on the same picture.
    private var spans: [URL: Span?] = [:]

    /// The subject's span. Runs Vision at most once per URL.
    func span(for url: URL, image: NSImage) async -> Span? {
        if let hit = cached(url) { return hit }
        let allowance = Self.crownAllowance
        let span = await Task.detached(priority: .utility) {
            Self.subjectSpan(of: image, crownAllowance: allowance)
        }.value
        store(span, for: url)
        return span
    }

    // The lock is taken and released inside these two, never across the `await`
    // above: NSLock is not safe to hold over a suspension point.

    /// Doubly optional on purpose: the outer layer is "have we run Vision on
    /// this URL", the inner is "did Vision find anything".
    private func cached(_ url: URL) -> Span?? {
        lock.lock(); defer { lock.unlock() }
        return spans[url]
    }

    private func store(_ span: Span?, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        spans[url] = span
    }

    private static func subjectSpan(of image: NSImage, crownAllowance: CGFloat) -> Span? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        return faceSpan(handler, crownAllowance: crownAllowance) ?? attentionSpan(handler)
    }

    /// Union of every face, extended upward to take in the crown. Nil when the
    /// picture has nobody in it, which is the common case.
    private static func faceSpan(_ handler: VNImageRequestHandler, crownAllowance: CGFloat) -> Span? {
        let request = VNDetectFaceRectanglesRequest()
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty
        else { return nil }

        // Union rather than the first face, so a group photograph crops to
        // include everyone rather than centring on whoever Vision listed first.
        let union = faces.dropFirst().reduce(faces[0].boundingBox) { $0.union($1.boundingBox) }
        // Vision's origin is bottom-left, so the crown is above the box's maxY.
        let crowned = min(1, union.maxY + union.height * crownAllowance)
        return Span(top: 1 - crowned, bottom: 1 - union.minY)
    }

    private static func attentionSpan(_ handler: VNImageRequestHandler) -> Span? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let objects = observation.salientObjects,
              !objects.isEmpty
        else { return nil }

        // Union of every salient box, so a picture with two subjects crops to
        // include both rather than centring on whichever Vision listed first.
        let union = objects.dropFirst().reduce(objects[0].boundingBox) { $0.union($1.boundingBox) }
        return Span(top: 1 - union.maxY, bottom: 1 - union.minY)
    }
}
