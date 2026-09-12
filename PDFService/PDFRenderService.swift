import Foundation
import PDFKit

/// The PDF helper: parses hostile bytes so the app does not have to.
///
/// Everything dangerous happens in this process. It holds no network
/// entitlement, no file-system entitlement and no user data, so the worst a
/// PDFKit memory-safety bug can do here is kill a process that launchd will
/// restart on the next request.
///
/// One document per connection, and **one process per document as well, but
/// only because this asks for it.**
///
/// An earlier version of this comment claimed the process was per-connection
/// because of `ServiceType = Application`. `man 5 xpcservice.plist` says the
/// opposite in as many words: each *application* gets one instance, and a later
/// connection reaches the existing service. There is no per-connection service
/// type. What is genuinely per-connection is this Swift object — so the state
/// claim held and the address-space claim did not, which is the half that
/// matters for the C parser this process exists to contain.
///
/// `ServiceDelegate` therefore exits when its connection goes, so a document
/// cannot leave anything behind in a process the next one will reuse.
final class PDFRenderService: NSObject, PDFRenderServiceProtocol, @unchecked Sendable {

    /// Serialises PDFKit. `PDFDocument` is not documented thread-safe and the
    /// connection delivers each message on its own queue.
    private let queue = DispatchQueue(label: "cc.jorviksoftware.pdfservice.render")
    private var document: PDFDocument?

    /// Rendering ceilings, so a malformed page cannot ask for an unbounded
    /// allocation. A page declaring 200,000 points square is a hostile page,
    /// not a poster.
    private static let maxRenderSide: CGFloat = 10_000

    /// How long one page may draw before the helper says which page it is.
    private static let renderWarning: TimeInterval = 10

    /// Off `queue`, because `queue` is the thread doing the drawing.
    private static let watchdog = DispatchQueue(label: "cc.jorviksoftware.jdn.pdfwatchdog")
    private static let maxRenderPixels: CGFloat = 40_000_000

    func open(handle: FileHandle,
              reply: @escaping (Int, [Double], String?) -> Void) {
        queue.async {
            defer { try? handle.close() }
            let data: Data
            do {
                // The app has already capped what it downloaded, so this reads
                // a bounded file. Read to the end of the descriptor rather than
                // seeking by a declared length: nothing here trusts a number
                // that came from the document.
                data = try handle.readToEnd() ?? Data()
            } catch {
                reply(0, [], "could not read the downloaded bytes")
                return
            }
            guard !data.isEmpty else {
                reply(0, [], "no bytes arrived")
                return
            }
            guard let doc = PDFDocument(data: data) else {
                reply(0, [], "\(data.count) bytes downloaded, not readable as a PDF")
                return
            }
            self.document = doc
            // **A page count is a number the document chooses.** `open` walks
            // every page's crop box before replying and the reply is two
            // doubles per page, so a small file declaring an enormous page tree
            // is a concrete amplification at both ends. No real article PDF is
            // near this; the largest opened during development was 154 pages.
            guard doc.pageCount <= PDFPageSizes.maxPages else {
                reply(0, [], "this PDF declares \(doc.pageCount) pages, more than the "
                           + "\(PDFPageSizes.maxPages) this reader will open")
                return
            }
            // Flat: width, height, width, height… See the protocol for why
            // this is not [NSValue].
            var boxes: [CGSize] = []
            boxes.reserveCapacity(doc.pageCount)
            var absurd = 0
            for i in 0..<doc.pageCount {
                let size = doc.page(at: i)?.bounds(for: .cropBox).size ?? .zero
                // A `/MediaBox` height of about 400 digits parses, and this
                // returns a finite 1e75 for it. Sent as-is it became a frame
                // height of roughly 7e119 in the app. `.zero` is the value the
                // app already treats as "no size given".
                if PDFPageSizes.isUsable(size) {
                    boxes.append(size)
                } else {
                    boxes.append(.zero)
                    absurd += 1
                }
            }
            if absurd > 0 {
                NSLog("pdf helper: %d page(s) declare a size no layout can use", absurd)
            }
            let sizes = PDFPageSizes.flatten(boxes)
            reply(doc.pageCount, sizes, nil)
        }
    }

    func render(page: Int, width: Double, scale: Double,
                reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            guard let doc = self.document else {
                reply(nil, "no document open")
                return
            }
            guard page >= 0, page < doc.pageCount, let p = doc.page(at: page) else {
                reply(nil, "page \(page) is not in this document")
                return
            }
            let box = p.bounds(for: .cropBox)
            // The same test `open` applies, so the helper cannot refuse to
            // describe a page and then agree to draw it.
            guard PDFPageSizes.isUsable(box.size) else {
                reply(nil, "page \(page) declares a size no layout can use")
                return
            }

            // Fit to the requested width, then clamp. The clamp is what stops a
            // page with an absurd aspect ratio turning a reasonable width into
            // an unreasonable height.
            let targetWidth = max(1, CGFloat(width) * CGFloat(scale))
            var size = CGSize(width: targetWidth,
                              height: targetWidth * (box.height / box.width))
            let side = max(size.width, size.height)
            if side > Self.maxRenderSide {
                let k = Self.maxRenderSide / side
                size = CGSize(width: size.width * k, height: size.height * k)
            }
            if size.width * size.height > Self.maxRenderPixels {
                let k = (Self.maxRenderPixels / (size.width * size.height)).squareRoot()
                size = CGSize(width: size.width * k, height: size.height * k)
            }

            // **A watchdog on the helper's own work, which is what the
            // client's deadline comment always said the deadline should be
            // measuring.** The render ceilings bound pixels; nothing bounds
            // the work behind them, and a few hundred thousand path operations
            // on one page costs minutes of CPU regardless of output size.
            // `thumbnail(of:for:)` polls no cancellation, so this cannot stop
            // the draw — what it does is tell the app which page is at fault,
            // instead of leaving the client to conclude from silence that the
            // helper crashed and take the whole document down with it.
            let slow = DispatchWorkItem {
                NSLog("pdf helper: page %d is still drawing after %.0fs", page, Self.renderWarning)
            }
            Self.watchdog.asyncAfter(deadline: .now() + Self.renderWarning, execute: slow)
            defer { slow.cancel() }

            // `thumbnail(of:for:)` is PDFKit's own rasteriser and draws the
            // page in this process, which is the whole point of this process.
            let image = p.thumbnail(of: size, for: .cropBox)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                reply(nil, "page \(page) would not rasterise")
                return
            }
            reply(png, nil)
        }
    }

    func text(page: Int, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let doc = self.document, page >= 0, page < doc.pageCount else {
                reply(nil)
                return
            }
            reply(doc.page(at: page)?.string)
        }
    }
}

/// One service object per connection, so a second document cannot see the
/// first one's state.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let exported = PDFRenderService()
        connection.exportedInterface = NSXPCInterface(with: PDFRenderServiceProtocol.self)
        // FileHandle is not in the default allow-list for an argument class, so
        // it is declared explicitly. Without this the call fails at runtime
        // rather than at compile time.
        connection.exportedInterface?.setClasses(
            NSSet(objects: FileHandle.self) as! Set<AnyHashable>,
            for: #selector(PDFRenderServiceProtocol.open(handle:reply:)),
            argumentIndex: 0, ofReply: false)
        connection.exportedObject = exported
        // Die with the document. See the note on PDFRenderService: the service
        // type does not give a process per connection, so this does.
        connection.invalidationHandler = { exit(0) }
        connection.interruptionHandler = { exit(0) }
        connection.resume()
        return true
    }
}
