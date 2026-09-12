import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// An `AVURLAsset` whose every byte is fetched by us, so the app's address
/// policy sees each request instead of only the first.
///
/// **`AVPlayer(url:)` followed a redirect straight out of the policy.** The
/// pre-flight and the player are two different requests through two different
/// stacks: the pre-flight is `URLSession` with `RedirectGuard` installed and
/// `WebURL.isAllowed` applied, and the player is AVFoundation, which has no
/// delegate, no guard and no check on any hop. A server can tell them apart by
/// user agent — `CFNetwork` against `AppleCoreMedia` — answer the pre-flight
/// with a genuine `ftyp` MP4 prefix, and answer the player with
/// `302 Location: http://127.0.0.1:9102/internal/admin`. Measured end to end
/// against the shipped `VideoPreflight`: verdict `play`, and the private server
/// logged the request arriving.
///
/// It was blind — the body never returns to the attacker, and playback then
/// failed with `AVFoundationErrorDomain -11850` — but the request arriving is
/// the harm: one arbitrary host, port, path and query on the reader's own
/// network, issued from inside the perimeter, per press of Play.
///
/// Following the redirects in the pre-flight and handing the player the final
/// URL is **not** a fix. It closes the case where both requests are redirected
/// and loses to the server that redirects only the player, which is the same
/// two-request divergence `VideoPreflight`'s own header already describes for
/// content substitution.
///
/// So the player is given a private scheme it cannot resolve on its own, and
/// every range it asks for is served here, through `URLSession` with
/// `RedirectGuard` attached and `WebURL.isAllowed` applied to the result. There
/// is no request AVFoundation can make that this does not see.
///
/// What it does not change: decoding a genuine video still happens in this
/// process. `AVPlayer` renders through a view, so unlike PDFKit it cannot be
/// moved into a helper.
@MainActor
final class PolicedVideoAsset {

    /// A scheme AVFoundation has no loader for, so every request must come
    /// here. Not a real scheme anywhere, deliberately.
    private static let scheme = "jdn-video"

    private let loader: Loader
    let asset: AVURLAsset

    /// nil when the address is one the policy refuses outright, which the
    /// pre-flight will already have said.
    init?(url: URL) {
        guard WebURL.isAllowed(url) else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = Self.scheme
        guard let masked = parts.url else { return nil }

        loader = Loader(origin: url)
        asset = AVURLAsset(url: masked)
        asset.resourceLoader.setDelegate(loader, queue: Loader.queue)
    }

    /// Held by `AVAssetResourceLoader` weakly, so the asset alone is not enough
    /// to keep it alive — this class owns both.
    private final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

        static let queue = DispatchQueue(label: "cc.jorviksoftware.jdn.videoloader")

        /// The real address, which the player never sees.
        private let origin: URL
        private let session: URLSession
        private let lock = NSLock()
        private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

        init(origin: URL) {
            self.origin = origin
            let config = URLSessionConfiguration.default
            // The same wall-clock bound the rest of the app's sinks carry.
            // `timeoutIntervalForResource` on `URLSession.shared` is 604,800 s.
            config.timeoutIntervalForResource = 600
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: config)
            super.init()
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource
                            loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            guard let data = loadingRequest.dataRequest else {
                // An information-only request: ask for one byte and read the
                // headers off the answer.
                fetch(range: 0..<1, for: loadingRequest, wantsBody: false)
                return true
            }
            // `currentOffset` is where the player has got to within this
            // request; serve from there so a partial answer is not re-sent.
            let start = data.currentOffset
            let remaining = data.requestedOffset + Int64(data.requestedLength) - start
            // A very large `requestedLength` is the player asking for the rest
            // of the file. Answer a chunk; it will ask again.
            let length = min(max(1, remaining), Int64(Self.tailChunk))
            fetch(range: start..<(start + length), for: loadingRequest, wantsBody: true)
            return true
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            didCancel loadingRequest: AVAssetResourceLoadingRequest) {
            lock.lock()
            let task = inFlight.removeValue(forKey: ObjectIdentifier(loadingRequest))
            lock.unlock()
            task?.cancel()
        }

        /// How much to ask for when the player wants "the rest of the file".
        /// It will ask again; a whole-file request would defeat the point of a
        /// ranged fetch.
        private static let tailChunk = 1 << 20

        private func fetch(range: Range<Int64>,
                           for loadingRequest: AVAssetResourceLoadingRequest,
                           wantsBody: Bool) {
            var request = URLRequest(url: origin)
            request.timeoutInterval = 20
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                             forHTTPHeaderField: "Range")
            // The same identity the pre-flight used, so a server cannot answer
            // the two differently by user agent — which is the whole trick this
            // file exists to stop.
            request.setValue(VideoPreflight.userAgent, forHTTPHeaderField: "User-Agent")

            let task = session.dataTask(with: request) { [weak self] body, response, error in
                guard let self else { return }
                self.lock.lock()
                self.inFlight.removeValue(forKey: ObjectIdentifier(loadingRequest))
                self.lock.unlock()

                if let error {
                    loadingRequest.finishLoading(with: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    loadingRequest.finishLoading(with: Failure.notHTTP)
                    return
                }
                // Belt as well as the redirect guard: whatever the chain did,
                // this is where it ended up.
                guard let final = http.url, WebURL.isAllowed(final) else {
                    jdnLog("video: refused a response from \(http.url?.host ?? "?")")
                    loadingRequest.finishLoading(with: Failure.refused)
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    loadingRequest.finishLoading(with: Failure.http(http.statusCode))
                    return
                }
                if let info = loadingRequest.contentInformationRequest {
                    Self.describe(http, into: info)
                }
                if wantsBody, let body, let data = loadingRequest.dataRequest {
                    data.respond(with: body)
                }
                loadingRequest.finishLoading()
            }
            // `RedirectGuard` is a task delegate, so each hop is judged before
            // it is followed rather than after it has been made.
            task.delegate = RedirectGuard()
            lock.lock()
            inFlight[ObjectIdentifier(loadingRequest)] = task
            lock.unlock()
            task.resume()
        }

        /// What the player needs before it will ask for anything else.
        private static func describe(_ http: HTTPURLResponse,
                                     into info: AVAssetResourceLoadingContentInformationRequest) {
            if let mime = http.mimeType, let type = UTType(mimeType: mime) {
                info.contentType = type.identifier
            }
            // `Content-Range: bytes 0-0/12345` carries the whole length; a
            // plain `Content-Length` from a ranged answer carries only the
            // slice.
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = range.split(separator: "/").last, let length = Int64(total) {
                info.contentLength = length
                info.isByteRangeAccessSupported = true
            } else {
                info.contentLength = http.expectedContentLength
                info.isByteRangeAccessSupported = false
            }
        }

        enum Failure: Error {
            case notHTTP
            case refused
            case http(Int)
        }
    }
}
