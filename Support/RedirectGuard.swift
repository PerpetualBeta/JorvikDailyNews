import Foundation

/// Applies the app's address policy to every hop of a redirect chain, not just
/// the first.
///
/// **Why this exists.** `WebURL.isAllowed` was tested on the URL the app asked
/// for, and `URLSession` then followed up to 20 redirects on its own with
/// nothing testing where it ended up. A subscribed feed answering
/// `302 Location: http://192.168.1.1/` therefore walked the user's own network,
/// and the single check the whole URL policy rests on was cosmetic.
///
/// The worst path was not the reader but the enricher: `ImageEnricher` fetches
/// article pages for every item missing a picture or a standfirst, hundreds per
/// refresh, every hour, with no interaction at all, and writes what comes back
/// into the summary the paper prints.
///
/// This is not the documented DNS-rebinding residual. That needs the same name
/// to resolve twice to different addresses; this needs a `Location` header.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// The caller's own delegate, if it had one. Composed rather than replaced:
    /// `ImageCache` passes a delegate to measure cache hit rate, and silently
    /// dropping it would have turned a security fix into a reporting bug.
    private let wrapped: URLSessionTaskDelegate?

    init(wrapping wrapped: URLSessionTaskDelegate? = nil) {
        self.wrapped = wrapped
    }

    /// Whether a hop is allowed to be followed.
    ///
    /// Separated from the delegate method so the suite can exercise the rule
    /// without constructing a `URLSessionTask`, which cannot be made by hand.
    static func permits(_ url: URL?) -> Bool {
        guard let url else { return false }
        return WebURL.isAllowed(url)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard Self.permits(request.url) else {
            jdnLog("redirect: refused \(response.statusCode) to "
                   + "\(request.url?.host ?? request.url?.absoluteString ?? "(none)")"
                   + " — outside the policy")
            // nil ends the chain and returns the redirect response itself, so
            // the caller sees a 3xx body rather than the refused resource.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    // MARK: - Pass-through

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        wrapped?.urlSession?(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        wrapped?.urlSession?(session, task: task, didCompleteWithError: error)
    }
}
