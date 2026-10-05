import Foundation

/// Fetches a body with a hard ceiling on how many bytes it will hold.
///
/// `URLSession.data(for:)` buffers the whole response before returning, and it
/// obeys no size limit, so the caller learns how big the answer was only after
/// paying for it. A hostile host that answers a 2 KB request with an endless
/// stream simply grew the app until the machine gave up; `file:///dev/zero`
/// reached 3.2 GB resident inside a second.
///
/// The timeout does not save you either: `URLRequest.timeoutInterval` is an
/// *idle* timeout, so a server dribbling one byte every few seconds keeps the
/// connection alive indefinitely while the buffer grows.
///
/// So this streams and stops. It also refuses a scheme the app has no business
/// fetching, which is the same rule as `WebURL` and is repeated here on
/// purpose: this is the sink, and a sink that trusts its callers is one
/// forgotten call site away from reading `file:///etc/passwd` — which it did,
/// returning 9,344 bytes, with the HTTP status check skipped because a file
/// response is not an `HTTPURLResponse`.
enum BoundedFetch {

    // MARK: - Ceilings
    //
    // Every number below is measured against what the app has actually
    // downloaded, taken from its own log, with headroom. They are ceilings on
    // absurdity, not on ambition: nothing legitimate has ever come close.

    /// Feed XML and article HTML. Largest real body seen: **4,969,342 bytes**.
    static let markupLimit = 32 * 1024 * 1024

    /// An image on the wire. The largest picture the app has *decoded* is 16 MB
    /// in memory, and compressed sources are far smaller than that.
    static let imageLimit = 32 * 1024 * 1024

    /// A PDF. Largest real one seen: **7,443,085 bytes**. Academic PDFs get
    /// genuinely large, so this is the most generous of the three.
    static let documentLimit = 256 * 1024 * 1024

    /// A page fetched only for what is in its `<head>`.
    ///
    /// `ImageEnricher` asks for `Range: bytes=0-32768` and then trims to 32 KB
    /// — but a Range header is a request, not a rule, and the fetch ceiling it
    /// passed was `markupLimit`, 32 MB. Nothing sets `Accept-Encoding` either,
    /// so URLSession negotiates gzip and this counts the *inflated* stream: a
    /// zero-filled body measured 1028:1, with `expectedContentLength` reported
    /// as -1 so the early bail never fired. Hundreds of candidates per refresh,
    /// eight at a time, every hour, with no interaction — for data thrown away
    /// one line later.
    static let headLimit = 256 * 1024

    /// How much is held before it is moved into the body. Small enough that
    /// the ceiling cannot be overshot by more than this.
    private static let chunkSize = 64 * 1024

    enum Failure: Error, LocalizedError {
        case schemeNotAllowed(String)
        case tooLarge(limit: Int)

        var errorDescription: String? {
            switch self {
            case .schemeNotAllowed(let scheme):
                return "\(scheme): is not a web address"
            case .tooLarge(let limit):
                return "the response is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))"
            }
        }
    }

    /// The response body, or a failure, never more than `limit` bytes held.
    /// - Parameter truncating: when true, reaching `limit` stops the read and
    ///   returns what has arrived, instead of throwing. For a caller that only
    ///   wants the head of a document — `ImageEnricher` keeps 32 KB — the
    ///   alternative is either buffering a body it will discard, or failing on
    ///   every page longer than the ceiling. Real pages measured today run to
    ///   693 KB, so failing would have been a regression dressed as a fix.
    /// The session every caller that used to pass `.shared` now passes.
    ///
    /// **`URLSession.shared` has a `timeoutIntervalForResource` of 604,800
    /// seconds — seven days**, measured on this machine. This file's own
    /// header already explains that `timeoutInterval` is an idle timeout and
    /// that "a server dribbling one byte every few seconds keeps the
    /// connection alive indefinitely", so on the shared session there was no
    /// wall-clock bound at all behind that sentence.
    ///
    /// Four call sites passed `.shared`: the feed fetch, feed discovery, the
    /// page enricher and the article extractor. The picture cache, the PDF
    /// download and the video preflight already had their own bounded
    /// sessions; these had none.
    ///
    /// Two minutes is far past any of these reads — the largest is a 32 MB
    /// markup limit and the enricher asks for 32 KB — and far inside the
    /// 300 s refresh watchdog.
    ///
    /// **It has its own disk cache, sized to hold the pages between refreshes.**
    /// Without one it used the app's default cache, measured 2026-10-05 at 12 MB
    /// on disk. One refresh pushed about 14 MB of feeds and pages through it, so
    /// an hour later only 41 of the 149 feeds were still there: everything was
    /// written to disk and almost none of it was there to be reused. `URLSession`
    /// asks "has this changed?" by sending the stored `ETag` or `Last-Modified`,
    /// but only for a response it still holds. Feeds have since moved to
    /// `feedSession`, which asks that question itself without storing them, so
    /// this cache now holds the page heads the enricher reads and the articles.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 120
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JorvikDailyNews/Fetches", isDirectory: true)
        // No memory copy: each body is parsed once and the result is kept, so a
        // second in-memory copy of the bytes would buy nothing.
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: cacheBytes, directory: dir)
        config.requestCachePolicy = .useProtocolCachePolicy
        jdnLog("fetch cache: \(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file)) on disk")
        return URLSession(configuration: config)
    }()

    /// Feeds only: the same ceilings as `session`, and no cache at all.
    ///
    /// `FeedFetcher` asks "has this changed?" itself and keeps what it needs in
    /// memory, so a disk cache here would only write every changed feed to disk
    /// again. With no cache, `URLSession` hands a 304 straight back to the
    /// caller instead of merging it into a stored copy.
    static let feedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// The largest feed or article body the app has downloaded, from its log.
    static let largestRealMarkupBody = 4_969_342

    /// The fetch cache's size on disk.
    ///
    /// `URLSession` only stores a response smaller than about 5% of the disk
    /// cache (Apple's documentation for
    /// `urlSession(_:dataTask:willCacheResponse:completionHandler:)`), so the
    /// largest real body needs twenty times its size before it can be kept at
    /// all. That is the default, rounded up to a whole megabyte. Read once, at
    /// the first fetch. A knob, so it can be tuned without a rebuild:
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews fetchCacheMaxBytes -int 209715200
    static var cacheBytes: Int {
        let stored = UserDefaults.standard.integer(forKey: "fetchCacheMaxBytes")
        if stored > 0 { return stored }
        let megabyte = 1024 * 1024
        let needed = largestRealMarkupBody * 20
        return (needed + megabyte - 1) / megabyte * megabyte
    }

    /// What the fetches cost since the last call, for the refresh log, and
    /// resets the count. Covers every fetch on `session` and `feedSession`: the
    /// refresh's feeds and page heads, feed discovery, and the articles opened
    /// since. A feed's 304 is `FeedFetcher`'s own question; a page's comes
    /// from the fetch cache.
    static func cacheSummary() -> String {
        let t = CacheTally.shared.drain()
        let mb = ByteCountFormatter.string(fromByteCount: Int64(t.downloadedBytes), countStyle: .file)
        return "fetches since the last refresh: \(t.downloaded + t.notModified + t.fromCache) "
            + "fetch(es); \(t.downloaded) downloaded (\(mb)), \(t.notModified) not modified (304), "
            + "\(t.fromCache) still fresh in the cache"
    }

    static func data(for request: URLRequest,
                     on session: URLSession,
                     limit: Int,
                     truncating: Bool = false,
                     delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw Failure.schemeNotAllowed("(no url)") }
        guard WebURL.isAllowed(url) else {
            throw Failure.schemeNotAllowed(url.scheme ?? "(none)")
        }

        // Every hop, not just the first. Without this the check above is
        // cosmetic: URLSession follows up to 20 redirects on its own and a
        // `Location` header pointing at the local network was followed.
        let counted = session === Self.session || session === Self.feedSession
        let guarded = RedirectGuard(wrapping: counted ? CacheTally.Counting(wrapping: delegate) : delegate)
        let (stream, response) = try await session.bytes(for: request, delegate: guarded)

        // Belt and braces. The delegate refuses a hop it is asked about; this
        // catches anything that arrives at a disallowed address by a route the
        // delegate never saw.
        if let final = response.url, !WebURL.isAllowed(final) {
            throw Failure.schemeNotAllowed(final.host ?? final.scheme ?? "(none)")
        }

        // A declared length over the ceiling is refused before a byte of body
        // is read. It is only a hint — a hostile host can understate or omit
        // it — so the streaming check below is what actually enforces the
        // limit, and this only saves the transfer.
        if !truncating,
           response.expectedContentLength > 0, response.expectedContentLength > Int64(limit) {
            throw Failure.tooLarge(limit: limit)
        }

        var body = Data()
        // Reserved from the ceiling only when the host declares a plausible
        // size. Reserving from an attacker's `Content-Length` is how a 20 KB
        // response asks for a gigabyte of address space.
        if response.expectedContentLength > 0 {
            body.reserveCapacity(min(Int(response.expectedContentLength), limit))
        }
        // Batched, because `AsyncBytes` yields one byte at a time and a
        // per-byte `Data.append` is the expensive part. Measured on a 5 MB
        // body — the largest the app has ever fetched — byte-wise iteration
        // costs 0.16s against 0.01s for the unbounded `data(for:)`. That is
        // the whole price of the ceiling, and it is paid once per refresh by
        // the two or three feeds that are megabytes rather than kilobytes.
        var chunk = [UInt8]()
        chunk.reserveCapacity(Self.chunkSize)
        for try await byte in stream {
            chunk.append(byte)
            guard chunk.count == Self.chunkSize else { continue }
            body.append(contentsOf: chunk)
            chunk.removeAll(keepingCapacity: true)
            if body.count > limit {
                // Stopping the iteration cancels the task, so the rest of the
                // body is never transferred rather than merely discarded.
                if truncating { return (body.prefix(limit), response) }
                throw Failure.tooLarge(limit: limit)
            }
        }
        body.append(contentsOf: chunk)
        if body.count > limit {
            if truncating { return (body.prefix(limit), response) }
            throw Failure.tooLarge(limit: limit)
        }
        return (body, response)
    }
}

/// Counts what each finished fetch on `BoundedFetch.session` cost, so the
/// effect of the fetch cache is measured rather than assumed.
///
/// `URLSessionTaskMetrics` is the only honest source, as `ImageCache` found:
/// a 304 reaches the caller as a 200 carrying the cached body, so the caller
/// cannot tell a revalidated feed from a downloaded one.
final class CacheTally: @unchecked Sendable {
    static let shared = CacheTally()

    struct Counts {
        var downloaded = 0
        var downloadedBytes = 0
        var notModified = 0
        var fromCache = 0
    }

    private let lock = NSLock()
    private var counts = Counts()

    func record(_ metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        let revalidated = metrics.transactionMetrics.contains {
            ($0.response as? HTTPURLResponse)?.statusCode == 304
        }
        lock.lock(); defer { lock.unlock() }
        if last.resourceFetchType == .localCache && !revalidated {
            counts.fromCache += 1
        } else if revalidated {
            counts.notModified += 1
        } else {
            counts.downloaded += 1
            counts.downloadedBytes += Int(last.countOfResponseBodyBytesReceived)
        }
    }

    func drain() -> Counts {
        lock.lock(); defer { lock.unlock() }
        let c = counts
        counts = Counts()
        return c
    }

    /// The delegate that feeds the tally, passing everything through to the
    /// caller's own delegate, as `RedirectGuard` does.
    final class Counting: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let wrapped: URLSessionTaskDelegate?

        init(wrapping wrapped: URLSessionTaskDelegate?) {
            self.wrapped = wrapped
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didFinishCollecting metrics: URLSessionTaskMetrics) {
            CacheTally.shared.record(metrics)
            wrapped?.urlSession?(session, task: task, didFinishCollecting: metrics)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: (any Error)?) {
            wrapped?.urlSession?(session, task: task, didCompleteWithError: error)
        }
    }
}
