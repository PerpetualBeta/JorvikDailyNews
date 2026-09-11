import AppKit
import Foundation

/// Talks to the sandboxed PDF helper, so PDFKit never parses a feed's bytes in
/// this process.
///
/// The app fetches and caps the bytes, writes them to a file in its own
/// container, and hands the helper a read-only descriptor. The helper holds no
/// network or file-system entitlement, so it can read those bytes and nothing
/// else. What comes back is PNG pixels and plain text.
///
/// **A crashed helper is a reported failure, not a silent blank.** That is the
/// case this whole design exists for: if a malformed PDF kills PDFKit, the
/// helper dies and the app must say so rather than show an empty pane. Four
/// places in this app once turned a failure into a blank pane, all found in one
/// day, so an unexplained empty rectangle is the specific failure mode worth
/// engineering against here.
@MainActor
final class PDFRenderClient {

    enum Failure: Error, CustomStringConvertible {
        case helperUnavailable
        case helperStopped
        case rejected(String)

        var description: String {
            switch self {
            case .helperUnavailable: return "the PDF helper would not start"
            case .helperStopped:     return "the PDF helper stopped while reading this document"
            case .rejected(let why): return why
            }
        }
    }

    struct Document {
        let pageCount: Int
        /// Each page's size in PDF points, for laying out before any page is
        /// rendered. Without this the reader would have to render every page to
        /// know how tall the document is.
        let sizes: [CGSize]
    }

    private var connection: NSXPCConnection?
    /// Set when the connection drops. Every later call fails fast with this
    /// rather than hanging on a proxy that will never answer.
    private var stopped = false

    // MARK: - Lifetime

    /// The live connection, created on first use.
    private func liveConnection() throws -> NSXPCConnection {
        if stopped { throw Failure.helperStopped }
        if let connection { return connection }
        let c = NSXPCConnection(serviceName: pdfRenderServiceName)
        c.remoteObjectInterface = NSXPCInterface(with: PDFRenderServiceProtocol.self)
        // FileHandle is not allow-listed by default for an argument class, so
        // it is declared on both sides or the call fails at run time.
        c.remoteObjectInterface?.setClasses(
            NSSet(array: [FileHandle.self]) as! Set<AnyHashable>,
            for: #selector(PDFRenderServiceProtocol.open(handle:reply:)),
            argumentIndex: 0, ofReply: false)
        // interruption = the helper died, which is the case this design is
        // for. invalidation = the connection will never work again.
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in
                jdnLog("pdf: helper interrupted — it stopped while reading a document")
                self?.stopped = true
            }
        }
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.stopped = true }
        }
        c.resume()
        connection = c
        return c
    }

    func close() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Calls

    /// Hands the bytes over and reports what the helper found.
    ///
    /// The file is unlinked as soon as it is open. The descriptor keeps the
    /// bytes readable, so nothing is left on disk for anything else to find,
    /// even if the app is killed mid-document.
    func open(_ data: Data) async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        guard let handle = try? FileHandle(forReadingFrom: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            throw Failure.rejected("could not stage the downloaded bytes")
        }
        try? FileManager.default.removeItem(at: tmp)

        let c = try liveConnection()
        defer { try? handle.close() }
        return try await withCheckedThrowingContinuation { k in
            var answered = false
            func once(_ r: Result<Document, Error>) {
                guard !answered else { return }
                answered = true
                k.resume(with: r)
            }
            guard let p = c.remoteObjectProxyWithErrorHandler({ error in
                jdnLog("pdf: helper failed to open the document — \(error.localizedDescription)")
                once(.failure(Failure.helperStopped))
            }) as? PDFRenderServiceProtocol else {
                once(.failure(Failure.helperUnavailable))
                return
            }
            p.open(handle: handle) { count, sizes, failure in
                if let failure { once(.failure(Failure.rejected(failure))) }
                else { once(.success(Document(pageCount: count,
                                              sizes: PDFPageSizes.unflatten(sizes)))) }
            }
        }
    }

    /// One page as an image, at `width` points and the given scale.
    func render(page: Int, width: CGFloat, scale: CGFloat) async throws -> NSImage {
        let c = try liveConnection()
        let png: Data = try await withCheckedThrowingContinuation { k in
            var answered = false
            func once(_ r: Result<Data, Error>) {
                guard !answered else { return }
                answered = true
                k.resume(with: r)
            }
            guard let p = c.remoteObjectProxyWithErrorHandler({ error in
                jdnLog("pdf: helper failed rendering page \(page) — \(error.localizedDescription)")
                once(.failure(Failure.helperStopped))
            }) as? PDFRenderServiceProtocol else {
                once(.failure(Failure.helperUnavailable))
                return
            }
            p.render(page: page, width: Double(width), scale: Double(scale)) { png, failure in
                if let png { once(.success(png)) }
                else { once(.failure(Failure.rejected(failure ?? "page would not render"))) }
            }
        }
        guard let image = NSImage(data: png) else {
            throw Failure.rejected("page \(page) came back unreadable")
        }
        return image
    }

    /// A page's text. Best-effort: search and copy are conveniences, so a
    /// helper that has gone returns nothing rather than an error.
    func text(page: Int) async -> String? {
        guard let c = try? liveConnection() else { return nil }
        return await withCheckedContinuation { k in
            var answered = false
            func once(_ v: String?) {
                guard !answered else { return }
                answered = true
                k.resume(returning: v)
            }
            guard let p = c.remoteObjectProxyWithErrorHandler({ _ in once(nil) })
                    as? PDFRenderServiceProtocol else {
                once(nil)
                return
            }
            p.text(page: page) { once($0) }
        }
    }
}
