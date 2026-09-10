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
    static func data(for request: URLRequest,
                     on session: URLSession,
                     limit: Int,
                     delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw Failure.schemeNotAllowed("(no url)") }
        guard WebURL.isAllowed(url) else {
            throw Failure.schemeNotAllowed(url.scheme ?? "(none)")
        }

        let (stream, response) = try await session.bytes(for: request, delegate: delegate)

        // A declared length over the ceiling is refused before a byte of body
        // is read. It is only a hint — a hostile host can understate or omit
        // it — so the streaming check below is what actually enforces the
        // limit, and this only saves the transfer.
        if response.expectedContentLength > 0, response.expectedContentLength > Int64(limit) {
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
            if body.count > limit { throw Failure.tooLarge(limit: limit) }
        }
        body.append(contentsOf: chunk)
        if body.count > limit { throw Failure.tooLarge(limit: limit) }
        return (body, response)
    }
}
