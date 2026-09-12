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
/// Receives `NSCache`'s eviction callbacks on the cache's behalf.
///
/// A separate object because `NSCacheDelegate` requires `NSObjectProtocol` and
/// `ImageCache` is a plain Swift class. It carries a closure rather than a back
/// reference so there is no ownership cycle to reason about.
private final class EvictionWatcher: NSObject, NSCacheDelegate {
    let onEvict: (NSImage) -> Void
    init(onEvict: @escaping (NSImage) -> Void) { self.onEvict = onEvict }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let image = obj as? NSImage else { return }
        onEvict(image)
    }
}

/// Reports whether a response came off the disk or off the network.
///
/// `URLSessionTaskMetrics.resourceFetchType` is the only honest answer.
/// Checking `URLCache.cachedResponse(for:)` before the request looks
/// equivalent and is not: it cannot tell a served entry from one that had to
/// be revalidated, and the point of measuring is to know the real hit rate
/// rather than a number that flatters the change.
private final class FetchSource: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var fromDisk = false

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        fromDisk = last.resourceFetchType == .localCache
    }
}

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// Pictures are fetched on their own session so they can have a disk
    /// cache, which `URLSession.shared` was not giving them.
    ///
    /// Measured before this existed: the app's URL cache held **one** entry,
    /// so every launch re-downloaded every picture — around 350 requests for
    /// a full edition, every time, from sites that are mostly small and
    /// independent. The decoded bitmaps were already cached in memory, but
    /// memory does not survive a quit.
    ///
    /// `memoryCapacity: 0` deliberately. `images` already holds the decoded
    /// bitmap, and a second in-memory copy of the compressed bytes buys
    /// nothing but pressure on the very thing it is meant to protect.
    ///
    /// `.useProtocolCachePolicy` means the CDN decides. A host sending
    /// `immutable` (GitHub's opengraph service says
    /// `public, max-age=21600, immutable`) will hit almost every time; a host
    /// sending `no-store` will never be cached, and that is its right. So the
    /// hit rate is not predictable in advance, which is why it is logged.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JorvikDailyNews/Images", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 0,
                                   diskCapacity: diskCacheBytes,
                                   directory: dir)
        config.requestCachePolicy = .useProtocolCachePolicy
        // **`timeoutInterval` is an idle timeout, and this session had no
        // wall-clock ceiling at all.** `BoundedFetch`'s own header says it in
        // as many words: "a server dribbling one byte every few seconds keeps
        // the connection alive indefinitely". Measured against a loopback
        // server sending one byte every 2 to 3 seconds: the transfer survived
        // 45 s with one byte delivered and did not throw, and a second copy
        // was still connected at 16 minutes 26 seconds.
        //
        // `timeoutInterval` was set at six sites in this app and
        // `timeoutIntervalForResource` at none.
        config.timeoutIntervalForResource = resourceCeiling
        return URLSession(configuration: config)
    }()

    /// Longest any one picture transfer may take, however it is paced.
    ///
    /// Generous for a large photograph on a slow line and far below the point
    /// where a refresh is at risk: the whole refresh is abandoned at 300 s.
    static let resourceCeiling: TimeInterval = 60

    /// 256 MB of compressed pictures on disk. A full edition's images run to
    /// tens of megabytes, so this holds several days and evicts by itself.
    /// Independent of the in-memory ceiling, which is sized from RAM.
    private static let diskCacheBytes = 256 * 1024 * 1024

    /// Hits and misses, so the benefit is measured rather than assumed.
    private var servedFromDisk = 0
    private var servedFromNetwork = 0
    private var firstPictureAt: Date?
    private var launchWindowReported = false

    /// The rate is only meaningful over the pictures a cache could possibly
    /// serve, which is the ones already on the page from last time.
    ///
    /// Measured on 2026-09-09: **all 14 disk hits of a session arrived within
    /// one second of launch, and none of the following 76 pictures came from
    /// disk.** A lifetime figure of "14 of 126, 11%" is arithmetically true
    /// and invites exactly the wrong conclusion, because everything after the
    /// launch window is a story that did not exist an hour ago and no cache
    /// can help with a picture nobody has ever fetched. So the hit rate is
    /// reported once, over the launch window, and then not again: within a
    /// session the in-memory cache handles page turns and reflows anyway.
    ///
    /// The window closes on whichever comes first, so a quiet launch that
    /// never reaches fifty pictures still reports.
    private static let launchWindowPictures = 50
    private static let launchWindowSeconds: TimeInterval = 5

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

    /// Running total of decoded bytes the cache is holding, for diagnostics.
    ///
    /// `NSCache` does not report its own current cost, so a tally is the only
    /// way to see how close a machine runs to `totalCostLimit` — which is the
    /// measurement that decides whether the picture work is what starves a
    /// small machine.
    ///
    /// **Its own lock, deliberately.** `NSCache` can evict synchronously from
    /// inside `setObject`, on the calling thread, so the delegate callback can
    /// land while `finish` is still running. Guarding this with the main `lock`
    /// would then take a non-recursive `NSLock` twice on one thread and
    /// deadlock the app. `NSCache` is itself thread-safe and never needed the
    /// main lock; only `failed`, `retryAfter` and `inFlight` do.
    private let bytesLock = NSLock()
    private var heldBytes = 0
    private var heldCount = 0
    private var evictionWatcher: EvictionWatcher?

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
    /// A decoded picture, plus the size it arrived at, so the log can show
    /// whether the scaling actually did anything for this one.
    private struct Decoded {
        let image: NSImage
        /// What the picture looks like, taken from the bitmap that was just
        /// decoded for display. Computed here because the `CGImage` is already
        /// in hand, so it costs one resample to 9x8 and no second decode.
        let signature: PictureSignature?
        let sourceWidth: Int
        let sourceHeight: Int
        /// The decoded bitmap's own dimensions, straight from the `CGImage`.
        ///
        /// Carried separately because nothing else here knows them. The log and
        /// `byteCost` both read `NSImage.representations.first`, and until now
        /// no line compared that against the bitmap it came from. Two fixes for
        /// oversized pictures were shipped on the assumption they agreed, and
        /// the evidence for both was a log line derived from the rep alone.
        let cgWidth: Int
        let cgHeight: Int
        /// Whether the compressed bytes came off the disk cache rather than
        /// the network. Reported so the disk cache's worth is a measurement.
        var fromDisk = false
        /// What the decoder was asked for, and how many times.
        let target: Int
        let requested: Int
        let attempts: Int
    }

    private enum Outcome {
        case image(Decoded)
        /// The URL is bad and will stay bad. Carries why, because "no picture"
        /// and "picture rejected" were indistinguishable in the log: every one
        /// of this file's log lines was a success path, so a front page of
        /// text-only cards could not be told from a front page of failures.
        case permanent(String)
        /// The request failed; the URL may be fine. Carries why.
        case transient(String)
    }

    init() {
        // Both limits, deliberately. `countLimit` bounds how many pictures are
        // held; only `totalCostLimit` bounds how much memory they take, and it
        // is the second that decides whether a 24-story front page fits on a
        // small machine. 500 full-resolution heroes could be several GB.
        images.countLimit = 500
        images.totalCostLimit = Self.cacheByteLimit

        let watcher = EvictionWatcher { [weak self] image in
            guard let self else { return }
            let cost = Self.byteCost(of: image)
            self.bytesLock.lock()
            self.heldBytes = max(0, self.heldBytes - cost)
            self.heldCount = max(0, self.heldCount - 1)
            let held = self.heldBytes, count = self.heldCount
            self.bytesLock.unlock()
            jdnLog("image: EVICTED \(Self.mb(cost)) — holding \(Self.mb(held)) of "
                   + "\(Self.mb(Self.cacheByteLimit)) across \(count)")
        }
        evictionWatcher = watcher
        images.delegate = watcher
    }

    /// One line describing every picture-related setting in force, written at
    /// launch so a log identifies which mode produced it.
    ///
    /// Without this a log from a pictures-off run is indistinguishable from a
    /// run where no picture ever loaded, which is exactly the ambiguity that
    /// makes a reporter's log unusable.
    static var configSummary: String {
        let ram = ProcessInfo.processInfo.physicalMemory
        guard picturesEnabled else {
            return "config: pictures OFF (showPictures=NO) — no downloads, no Vision; "
                 + "\(ram / 1_073_741_824) GB machine"
        }
        return "config: pictures ON, maxPixelSize \(maxPixelSize)px, "
             + "cache cap \(mb(cacheByteLimit)) on a \(ram / 1_073_741_824) GB machine, "
             + "hideReadItems=\(UserDefaults.standard.bool(forKey: "hideReadItems"))"
    }

    private static func mb(_ bytes: Int) -> String {
        // `.memory`, not `.file`: these are decoded bitmaps against a limit
        // derived from physical RAM, and memory is the one thing macOS still
        // counts in binary. A file size in the same app uses `.file`, which
        // is what Finder shows — the two conventions differ by 5% and the
        // right one depends on what is being measured.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Drop everything at the turn of the day.
    ///
    /// The memory cache has no expiry and is consulted **before** the disk
    /// cache, so the layer with proper HTTP freshness checking sits behind a
    /// layer with none: a CDN serving different bytes at the same URL would be
    /// noticed on revalidation and never get that far. Putting a TTL on the
    /// memory cache would mean re-decoding pictures the CDN would have said
    /// were still fresh, which costs more than it saves. An edition lasts a
    /// day, so the day boundary is the right granularity and makes the
    /// ordering moot.
    ///
    /// The negative caches go too. `failed` is a settled fact *for the
    /// session*, and a 404 yesterday is not evidence about today.
    func newDay() {
        lock.lock()
        let hadFailed = failed.count, hadCooling = retryAfter.count
        failed.removeAll()
        retryAfter.removeAll()
        lock.unlock()

        images.removeAllObjects()
        // Zero the tally AFTER emptying the cache. Whether `NSCache` calls its
        // delegate for `removeAllObjects` is unspecified, so the watcher may
        // have decremented already; it clamps at zero and this settles it
        // either way.
        bytesLock.lock()
        heldBytes = 0
        heldCount = 0
        bytesLock.unlock()

        // A new day is a new launch window as far as this measurement goes.
        firstPictureAt = nil
        launchWindowReported = false
        servedFromDisk = 0
        servedFromNetwork = 0

        SaliencyCache.shared.newDay()
        jdnLog("image: new day — dropped the picture cache, \(hadFailed) failed "
               + "URL(s) and \(hadCooling) in cool-off")
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
            // **`finish` marking a picture blank changed only the
            // bookkeeping.** It inserted the URL into `failed` and returned,
            // and then this line handed the same blank image to the caller
            // anyway, so the one value that flows to everyone said yes while
            // the record said no. The test is here as well, because `finish`
            // is where the signature is written to the store and moving it
            // earlier would lose that.
            if case .image(let decoded) = outcome {
                if decoded.signature?.isFeatureless == true { return nil }
                return decoded.image
            }
            return nil
        }
        // `finish` clears `inFlight`, and it is only reached when the download
        // returns. A transfer that never returns therefore left its entry in
        // place for ever, so every later refresh found the stuck entry and
        // joined it rather than trying again — which is how one dribbling
        // server stopped the paper publishing for the whole session.
        // `timeoutIntervalForResource` above bounds the transfer; this is the
        // belt for anything that still does not come back.
        inFlight[url] = task
        return task
    }

    private func finish(url: URL, outcome: Outcome) {
        lock.lock(); defer { lock.unlock() }
        inFlight[url] = nil
        switch outcome {
        case .image(let decoded):
            if let signature = decoded.signature {
                PictureSignatureStore.shared.record(signature, for: url)
                // A picture with nothing in it is not a picture. It decodes
                // perfectly, so this is the only place that can tell.
                if signature.isFeatureless {
                    failed.insert(url)
                    jdnLog("image: BLANK \(url.lastPathComponent) from "
                           + "\(url.host ?? "?") — \(decoded.cgWidth)x\(decoded.cgHeight) "
                           + "with no detail in it; not used")
                    return
                }
            }
            let cost = Self.byteCost(of: decoded.image)
            bytesLock.lock()
            heldBytes += cost
            heldCount += 1
            let held = heldBytes, count = heldCount
            bytesLock.unlock()
            images.setObject(decoded.image, forKey: url as NSURL, cost: cost)
            let scaled = (decoded.cgWidth != decoded.sourceWidth || decoded.cgHeight != decoded.sourceHeight)
            jdnLog("image: \(decoded.sourceWidth)x\(decoded.sourceHeight) -> \(decoded.cgWidth)x\(decoded.cgHeight)"
                   + "\(scaled ? " SCALED" : "") \(Self.mb(cost)) — holding \(Self.mb(held))"
                   + " of \(Self.mb(Self.cacheByteLimit)) across \(count) — \(url.host ?? "?")"
                   + (decoded.fromDisk ? " [disk]" : ""))
            if decoded.fromDisk { servedFromDisk += 1 } else { servedFromNetwork += 1 }
            let now = Date()
            if firstPictureAt == nil { firstPictureAt = now }
            let total = servedFromDisk + servedFromNetwork
            let elapsed = now.timeIntervalSince(firstPictureAt ?? now)
            if !launchWindowReported,
               total >= Self.launchWindowPictures || elapsed > Self.launchWindowSeconds {
                launchWindowReported = true
                jdnLog("image: \(servedFromDisk) of the first \(total) pictures came from the "
                       + "disk cache (\(100 * servedFromDisk / total)%) — the launch window, "
                       + "which is the only stretch a cache can serve; later pictures are "
                       + "stories that did not exist last time")
            }
            // The rep's dimensions are deliberately not used or reported. They
            // are scaled by the backing store and disagree with the bitmap on
            // every picture, which is expected; see `byteCost`.
            if decoded.attempts > 1 || decoded.requested != decoded.target {
                jdnLog("image: decode asked \(decoded.requested)px for a target of"
                       + " \(decoded.target)px in \(decoded.attempts) attempt(s)")
            }
            failed.remove(url)
            retryAfter[url] = nil
        case .permanent(let why):
            failed.insert(url)
            retryAfter[url] = nil
            jdnLog("image: REJECTED \(url.host ?? "?") — \(why); "
                   + "not asked again this session")
        case .transient(let why):
            retryAfter[url] = Date().addingTimeInterval(Self.transientCooloff)
            jdnLog("image: FAILED \(url.host ?? "?") — \(why); retrying after "
                   + "\(Int(Self.transientCooloff))s")
        }
    }

    /// The largest picture this reader pulls down whole.
    ///
    /// Above this it reads the head of the file instead, and draws the first
    /// frame if the bytes are a GIF. **An animation is the only thing that
    /// reaches this size for a reason the reader can use, and the only thing a
    /// prefix can be trusted for**: a truncated photograph decodes to its top
    /// few rows over grey, and half a picture is worse than none.
    ///
    /// Measured on `github.com/olesha-ai/edgeinfer-eval`, which embeds an
    /// 11,591,322-byte 172-frame GIF through a plain `<img src="video.gif">`.
    /// It arrived in 57.3 s and 61.6 s on two consecutive runs against a 60 s
    /// `resourceCeiling`, so it succeeded or failed on a coin toss — and on
    /// the losing toss the reader drew a spinner for a minute and then nothing
    /// at all. Its first frame decodes from the **first 128 KB**, identically
    /// to the full file: 800x450, mean luminance 69.5 and standard deviation
    /// 69.1 measured on both.
    ///
    /// Nothing is refused by this number. Over it the picture is fetched
    /// twice at worst, and the ordinary path below it is unchanged.
    static let fullFetchCeiling = 6 * 1024 * 1024

    /// How much of an oversized picture is read. Eight times what the measured
    /// case needed for a complete first frame.
    static let headFetchBytes = 1024 * 1024

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

    /// Whether these bytes begin a GIF.
    ///
    /// The one format here whose prefix is safe to draw. A GIF stores its
    /// frames whole and in order, so the first one is complete as soon as it
    /// has arrived. Every other format the cache accepts holds one picture,
    /// interleaved or not, so a prefix of it is a part-picture.
    static func isGIF(_ data: Data) -> Bool {
        data.prefix(4).elementsEqual([0x47, 0x49, 0x46, 0x38] as [UInt8])
    }

    private enum Fetched {
        case body(Data, URLResponse)
        /// The host declared, or sent, more than the limit asked for.
        case tooLarge
        /// Nothing more to try; this is the answer.
        case stop(Outcome)
    }

    /// One request, bounded. `head` asks for that many leading bytes and keeps
    /// whatever arrives, so a host that ignores `Range` is stopped by the
    /// streaming limit rather than trusted to obey.
    private static func fetch(_ url: URL, limit: Int, timeout: TimeInterval,
                              head: Int? = nil, source: FetchSource) async -> Fetched {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let head { request.setValue("bytes=0-\(head - 1)", forHTTPHeaderField: "Range") }
        do {
            let (data, response) = try await BoundedFetch.data(
                for: request, on: Self.session, limit: limit,
                truncating: head != nil, delegate: source)
            return .body(data, response)
        } catch let failure as BoundedFetch.Failure {
            // **A scheme the policy will never allow is not transient.** Filed
            // as one, the URL was retried on every refresh for the life of the
            // session, for ever, for an answer that cannot change.
            if case .schemeNotAllowed = failure {
                return .stop(.permanent(failure.localizedDescription))
            }
            if case .tooLarge = failure { return .tooLarge }
            return .stop(.transient(failure.localizedDescription))
        } catch {
            // A timeout, a dropped connection, a DNS hiccup. Nothing here says
            // the picture is bad.
            return .stop(.transient(error.localizedDescription))
        }
    }

    private static func download(_ url: URL, timeout: TimeInterval) async -> Outcome {
        let source = FetchSource()
        let data: Data
        let response: URLResponse

        switch await fetch(url, limit: fullFetchCeiling, timeout: timeout, source: source) {
        case .body(let d, let r):
            (data, response) = (d, r)
        case .stop(let outcome):
            return outcome
        case .tooLarge:
            // Too big to draw whole. Read the head and see whether it is an
            // animation, whose first frame — the only frame this reader ever
            // draws — is complete long before the file is.
            var prefix: (Data, URLResponse)?
            if case .body(let d, let r) = await fetch(url, limit: headFetchBytes,
                                                      timeout: timeout, head: headFetchBytes,
                                                      source: source), isGIF(d) {
                jdnLog("image: read the first \(mb(d.count)) of an animation from "
                       + "\(url.host ?? "?") and drew its first frame, rather than "
                       + "fetching the whole file")
                prefix = (d, r)
            }
            if let prefix {
                (data, response) = prefix
            } else {
                // Not an animation, so a prefix would be the top of a picture
                // over grey. Pay for the whole thing.
                switch await fetch(url, limit: BoundedFetch.imageLimit,
                                   timeout: timeout, source: source) {
                case .body(let d, let r): (data, response) = (d, r)
                case .stop(let outcome): return outcome
                case .tooLarge:
                    return .permanent("larger than the \(mb(BoundedFetch.imageLimit)) ceiling")
                }
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 5xx is the server having a bad day, 429 is us asking too fast and
            // 408 is a timeout by another name. All three are worth retrying.
            // Everything else — 404, 410, 403 — is an answer, not an accident.
            let retryable = http.statusCode >= 500 || http.statusCode == 429 || http.statusCode == 408
            let why = "HTTP \(http.statusCode)"
            return retryable ? .transient(why) : .permanent(why)
        }

        // Reject 1×1 trackers and icon-sized placeholders. Undecodable bytes and
        // a tracking pixel are both settled facts about the URL.
        guard let decoded = await decodeOffPool(data) else {
            return .permanent("undecodable, \(data.count) bytes")
        }
        let w = Int(decoded.image.size.width), h = Int(decoded.image.size.height)
        guard w >= Self.minimumPixels, h >= Self.minimumPixels else {
            return .permanent("\(w)x\(h) is below the \(Self.minimumPixels)px floor")
        }
        var stamped = decoded
        stamped.fromDisk = source.fromDisk
        return .image(stamped)
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
    /// How many times to ask the decoder before accepting what it gives.
    ///
    /// Two is enough for a decoder that scales the request by a constant, which
    /// is what macOS 27 does. Three leaves one spare.
    private static let maxDecodeAttempts = 3

    /// Smaller than this on either side and it is furniture, not a picture:
    /// a 1x1 tracker, a favicon, a broken-CDN placeholder. Drawing one blots
    /// the page with an empty rectangle.
    private static let minimumPixels = 48

    private static func thumbnail(from source: CGImageSource, longEdge: Int) -> CGImage? {
        // `kCGImageSourceCreateThumbnailWithTransform` applies the EXIF
        // orientation. Without it a photograph taken in portrait comes back on
        // its side, because the flag that says so is in metadata this path
        // discards. `CreateThumbnailFromImageAlways` ignores any thumbnail
        // already in the file, which is typically 160 px and renders as a badly
        // blurred hero.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Decode a picture no larger than the cap, and no larger than the file.
    ///
    /// `NSImage(data:)` decodes at whatever resolution the source publishes and
    /// holds it, so a 6000-pixel CDN original cost 77.2 MB as a bitmap against
    /// 9.0 MB scaled. ImageIO scales during decode, so the full-size bitmap is
    /// never allocated.
    ///
    /// Two things are then needed, and the first attempt at this shipped
    /// without either.
    ///
    /// **Never ask for more than the file has.** The cap is a ceiling, not a
    /// size. Asking for 2048 from a 1200-pixel image invites a decoder to
    /// answer with something larger than the file, which is not a saving in
    /// any direction.
    ///
    /// **Verify the answer and correct by what was measured.** macOS 27 scales
    /// the request by the display scale, so 2048 comes back as 4096. Measured
    /// on a reporter's 8 GB machine: 38 pictures in one session, every one
    /// decoded larger than its own file, 301.5 MB held against a 256 MB limit
    /// and 21 evictions. The previous attempt tried to fix that with a
    /// `CGContext` redraw and it silently did nothing, because both of its
    /// failure paths returned the original image with no log line.
    ///
    /// So this asks again instead, scaled by the ratio it just observed. That
    /// needs no knowledge of the display scale, which a background thread
    /// cannot reliably obtain, and it self-corrects on whatever a future
    /// decoder does. It costs one extra decode only where the first answer was
    /// wrong, and it says so in the log either way. There is no silent path.
    /// Largest source a picture may declare on either side.
    static let maxSourceSide = 40_000
    /// And in total. The largest real picture the app has decoded is 12.1 MP.
    static let maxSourcePixels = 80_000_000

    /// The picture formats a newspaper needs, by their own first bytes.
    ///
    /// **ImageIO decides which parser runs from the bytes, and the feed
    /// chooses the bytes.** `CGImageSourceCopyTypeIdentifiers()` returns 62
    /// UTIs on this machine, and CoreGraphics reaches PDF through a further
    /// fallback that is not even in that list. So a feed naming any picture —
    /// an `<enclosure>`, a `<media:content>`, an `og:image`, an `<img src>` in
    /// a description — could answer with PDF, DICOM, PICT, OpenEXR, Radiance,
    /// DDS or any of 25 camera RAW parsers, and pick which one ran. Nothing on
    /// this path looks at the declared MIME type.
    ///
    /// PDF mattered most: `PDFRenderClient` says the XPC helper exists "so
    /// PDFKit never parses a feed's bytes in this process", and the Makefile
    /// makes PDFKit's absence "a property of the link line rather than a claim
    /// in a comment" — but CGPDF, the parser underneath PDFKit, was reachable
    /// through ImageIO in the main process, which holds the network
    /// entitlement, on the unattended hourly path.
    ///
    /// Magic numbers rather than UTIs, because this has to be decided before
    /// `CGImageSourceCreateWithData` is handed the bytes at all.
    private static let acceptedSignatures: [[UInt8]] = [
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],   // PNG
        [0xFF, 0xD8, 0xFF],                                 // JPEG
        [0x47, 0x49, 0x46, 0x38],                           // GIF87a/89a
        [0x49, 0x49, 0x2A, 0x00],                           // TIFF, little endian
        [0x4D, 0x4D, 0x00, 0x2A],                           // TIFF, big endian
        [0x42, 0x4D],                                       // BMP
    ]

    /// The same list as UTIs, for the second check after the source is made.
    private static let acceptedTypes: Set<String> = [
        "public.png", "public.jpeg", "com.compuserve.gif", "public.tiff",
        "com.microsoft.bmp", "org.webmproject.webp", "public.heic",
        "public.heif", "public.heics", "public.avif",
    ]

    /// Whether these bytes are a picture format the paper actually uses.
    ///
    /// WebP, HEIC and AVIF are ISO-BMFF or RIFF containers, so they are
    /// matched on the brand at offset 4 rather than on a fixed prefix.
    static func isAcceptedPicture(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(16))
        guard head.count >= 4 else { return false }
        for signature in acceptedSignatures where head.starts(with: signature) { return true }
        if head.count >= 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]),   // RIFF
           Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true }  // WEBP
        if head.count >= 12, Array(head[4..<8]) == [0x66, 0x74, 0x79, 0x70] {   // ftyp
            let brand = String(decoding: head[8..<12], as: UTF8.self).lowercased()
            return ["heic", "heix", "hevc", "heim", "heis", "hevm", "mif1",
                    "msf1", "avif", "avis"].contains(brand)
        }
        return false
    }

    /// Where the decode is allowed to block.
    ///
    /// **`CGImageSourceCreateThumbnailAtIndex` polls no cancellation**, so
    /// neither `Task` cancellation nor the 300 s refresh watchdog can stop one
    /// once it starts. It used to run synchronously on a cooperative-pool
    /// thread, because `sharedTask` creates a plain unstructured `Task` from a
    /// nonisolated method. Measured with 24 concurrent decodes of one hostile
    /// fixture on 14 cores: an ordinary 0.5 s `Task.sleep` started at t=0 did
    /// not resume until t=9.1 s, and in a second run t=32.6 s.
    ///
    /// That is the same starvation `SaliencyCache` records in its own comment
    /// as having meant "no async work in the app could be scheduled again".
    /// Vision was moved off the pool for it and the decode was left on it.
    /// One pathological picture should cost one thread, not the runtime.
    private static let decodeQueue = DispatchQueue(label: "cc.jorviksoftware.jdn.decode",
                                                   qos: .utility)

    private static func decodeOffPool(_ data: Data) async -> Decoded? {
        await withCheckedContinuation { continuation in
            decodeQueue.async { continuation.resume(returning: decode(data)) }
        }
    }

    private static func decode(_ data: Data) -> Decoded? {
        guard isAcceptedPicture(data) else {
            jdnLog("image: REFUSED \(data.count) bytes that are not a picture format "
                   + "this reader decodes")
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Belt as well as braces: the signature above says what the bytes
        // claim, this says what ImageIO decided to be.
        if let type = CGImageSourceGetType(source) as String?, !acceptedTypes.contains(type) {
            jdnLog("image: REFUSED a source ImageIO reads as \(type)")
            return nil
        }
        // Source dimensions come from the metadata, so reading them costs no
        // decode.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let srcW = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let srcH = props?[kCGImagePropertyPixelHeight] as? Int ?? 0

        // Refuse an absurd canvas before ImageIO is asked to do anything with
        // it. The dimensions above are metadata, so this costs nothing.
        //
        // They were only ever used to LOWER the thumbnail request, never
        // tested against a ceiling. The classic truncated-header bomb is
        // already dead — ImageIO reports 0x0 and returns nil for those — but a
        // COMPLETE 1-bit greyscale PNG declaring 100000x100000 is 1,215,104
        // bytes on the wire and entirely valid. Measured running this exact
        // decode: **8.2 GB resident and 13.1 seconds** inside a single
        // `CGImageSourceCreateThumbnailAtIndex` asking for 2,048 px. 65535²
        // peaked at 4.0 GB in 5.6 s.
        //
        // 80 megapixels with neither side over 40,000 is far past any news
        // photograph: the largest the app has ever decoded is 4800x2520, which
        // is 12.1.
        // **A missing dimension is a refusal, not permission.** ImageIO
        // publishes no `kCGImagePropertyPixelWidth` for some formats — PDF
        // among them — so both defaulted to 0, this guard passed trivially,
        // `sourceLongEdge` was 0, and `target` became the full
        // `maxPixelSize`. The ceiling written to stop an absurd canvas was a
        // no-op for exactly the inputs that had no canvas to declare.
        guard srcW > 0, srcH > 0,
              srcW <= maxSourceSide, srcH <= maxSourceSide,
              srcW * srcH <= maxSourcePixels
        else {
            jdnLog("image: REFUSED a \(srcW)x\(srcH) source — beyond "
                   + "\(maxSourceSide)px a side or \(maxSourcePixels / 1_000_000) megapixels")
            return nil
        }

        let sourceLongEdge = max(srcW, srcH)
        let target = sourceLongEdge > 0 ? min(maxPixelSize, sourceLongEdge) : maxPixelSize

        var request = target
        var best: CGImage?
        var usedAttempts = 0
        for attempt in 1...maxDecodeAttempts {
            usedAttempts = attempt
            guard let cg = thumbnail(from: source, longEdge: request) else { break }
            best = cg
            let got = max(cg.width, cg.height)
            if got <= target {
                if attempt > 1 {
                    jdnLog("image: decode corrected at attempt \(attempt) — asked \(request)px, got \(got)px")
                }
                break
            }
            let corrected = max(1, Int((Double(request) * Double(target) / Double(got)).rounded(.down)))
            if corrected == request || attempt == maxDecodeAttempts {
                jdnLog("image: decoder will not honour \(target)px — asked \(request)px, got"
                       + " \(cg.width)x\(cg.height) after \(attempt) attempt(s); keeping it")
                break
            }
            request = corrected
        }
        guard let cg = best else { return nil }
        // Size in pixels, so `NSImage.size` and the bitmap agree. The 48pt
        // tracker threshold above is a pixel test in intent, and this is what
        // makes it one.
        return Decoded(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)),
                       signature: PictureSignature.of(cg),
                       sourceWidth: srcW, sourceHeight: srcH,
                       cgWidth: cg.width, cgHeight: cg.height,
                       target: target, requested: request, attempts: usedAttempts)
    }


    /// What a decoded picture costs the cache, in bytes: four per pixel.
    ///
    /// `NSCache` cost is in whatever unit you supply, so supplying bytes is
    /// what makes `totalCostLimit` a memory limit rather than a number.
    private static func byteCost(of image: NSImage) -> Int {
        // From `size`, NOT from `representations.first.pixelsWide`.
        //
        // A representation reports pixels scaled by the backing store. Measured
        // on this machine with the diagnostics added in 1.4.2: a **1200x675**
        // `CGImage` yields a rep of **2400x1350** while `NSImage.size` stays
        // 1200x675. Costing from the rep therefore charged **four times** the
        // real memory, two for width and two again for height.
        //
        // That single mistake is the whole of this saga. It made every picture
        // look larger than its own file, which is what 1.3.3 and 1.4.0 both
        // tried to fix, in the decoder, where nothing was wrong. On the
        // reporter's 8 GB machine it read 301.5 MB against a 256 MB limit and
        // forced 21 evictions; the true figure was near 75 MB and not one of
        // those evictions was needed.
        //
        // `size` is right here rather than by luck: `decode` constructs the
        // `NSImage` with `size` set from the `CGImage`'s own pixel dimensions,
        // so for every picture in this cache one point is one pixel. It is also
        // the only number available in the eviction callback, which receives an
        // `NSImage` and nothing else, so insert and evict now agree by
        // construction.
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        return max(1, width * height * 4)
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

    private init() { spans.countLimit = Self.spanCountLimit }

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
    /// Boxed so the spans can live in an `NSCache`, which is the whole point.
    ///
    /// The two levels of optional are both meaningful and had to survive the
    /// change: **no box** means this picture has never been examined, and a
    /// box holding nil means Vision looked and found nothing salient. Collapse
    /// those and every featureless picture gets re-examined on every reflow,
    /// which is a Vision request per card.
    private final class SpanBox {
        let span: Span?
        init(_ span: Span?) { self.span = span }
    }

    /// Was a plain `[URL: Span?]` with **no bound and no expiry**: every
    /// picture the app ever cropped added an entry for the life of the
    /// process and nothing ever removed one. Two `CGFloat`s an entry, so the
    /// leak is small, but an unbounded dictionary keyed by URL in an app that
    /// runs for days is the same shape of mistake as setting `countLimit`
    /// without `totalCostLimit`.
    ///
    /// `NSCache` also gives up its contents under memory pressure, which is
    /// right for a value that can be recomputed from a picture we still hold.
    private let spans = NSCache<NSURL, SpanBox>()
    /// Generous, because re-running Vision is expensive and a span is tiny.
    /// A day's edition is a few hundred pictures, so this is several days'
    /// worth and exists to stop unbounded growth rather than to be reached.
    private static let spanCountLimit = 4000

    /// Vision runs here, and nowhere else.
    ///
    /// A dedicated queue rather than `Task.detached`, and that is the whole
    /// point of it. `Task.detached` runs on Swift Concurrency's **cooperative
    /// pool**, which is exactly as wide as the machine's core count, and
    /// blocking one of its threads is forbidden: the thread is occupied, not
    /// yielded. Vision's `performRequests` is synchronous and blocks on a
    /// semaphore inside `VNControlledCapacityTasksQueue` whenever it is at
    /// capacity, so a full edition of pictures consumed the pool and **no
    /// async work in the app could be scheduled again**.
    ///
    /// Measured on a 14-core machine with a refresh in flight: 15 threads
    /// parked in `SaliencyCache.span` -> Vision -> `_dispatch_semaphore_wait_slow`
    /// against 14 cooperative threads, unchanged across two samples three
    /// seconds apart. The main thread was idle the whole time, waiting for
    /// work that could never be scheduled — which is why the symptom was "the
    /// OPML export hangs" and had nothing whatever to do with OPML.
    ///
    /// Serial on purpose. Vision limits its own concurrency anyway, so width
    /// above a small number buys nothing, and one thread cannot starve
    /// anything. The result is cached per URL, so the cost is paid once per
    /// picture per day.
    private static let visionQueue = DispatchQueue(label: "cc.jorviksoftware.jdn.vision",
                                                   qos: .utility)

    /// The subject's span. Runs Vision at most once per URL.
    func span(for url: URL, image: NSImage) async -> Span? {
        if let hit = cached(url) { return hit }
        let allowance = Self.crownAllowance
        let span: Span? = await withCheckedContinuation { continuation in
            Self.visionQueue.async {
                continuation.resume(returning: Self.subjectSpan(of: image,
                                                                crownAllowance: allowance))
            }
        }
        store(span, for: url)
        return span
    }

    // The lock is taken and released inside these two, never across the `await`
    // above: NSLock is not safe to hold over a suspension point.

    /// Doubly optional on purpose: the outer layer is "have we run Vision on
    /// this URL", the inner is "did Vision find anything".
    private func cached(_ url: URL) -> Span?? {
        // `NSCache` is thread-safe, so no lock of our own is needed here.
        guard let box = spans.object(forKey: url as NSURL) else { return nil }
        return .some(box.span)
    }

    private func store(_ span: Span?, for url: URL) {
        spans.setObject(SpanBox(span), forKey: url as NSURL)
    }

    /// Spans are derived from pictures, so when the pictures go, so do these.
    func newDay() { spans.removeAllObjects() }

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
