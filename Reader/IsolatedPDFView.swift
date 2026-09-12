import AppKit
import SwiftUI

/// Displays a PDF without parsing it.
///
/// The app downloads the bytes, caps them, and hands them to the sandboxed
/// helper; what comes back is a page count, each page's size in points, and
/// PNG images rendered on demand. PDFKit never runs in this process.
///
/// **What this costs, stated plainly.** `PDFView` cannot be used here, because
/// `PDFView` parses in-process — that is what it is for. So PDFKit's text
/// selection and its find bar are gone. Reading, scrolling and zooming remain;
/// zoom re-renders through the helper rather than scaling a bitmap, so a
/// magnified page is sharp rather than soft. Anyone who needs selection or
/// search has the "Open in your browser" button, which is also the reader's
/// existing answer for a PDF it cannot handle.
@MainActor
@Observable
final class IsolatedPDFModel {

    enum State {
        case starting
        case downloading(received: Int64, total: Int64)
        case ready(pageCount: Int)
        case failed(String)
    }

    var state: State = .starting
    /// Rendered pages, keyed by page index and the width they were drawn for.
    /// Keyed by width as well as index because a zoom change must not show the
    /// previous zoom's image scaled up.
    ///
    /// **An `NSCache` with a cost, not a dictionary.** This was a plain
    /// dictionary that was written and read and never evicted, while the zoom
    /// control offers fifteen steps and pages render at twice the layout width
    /// — so the ceiling was fifteen full-resolution bitmaps per page, roughly
    /// 14 MB each for A4 in an 800-point pane. The helper's ceilings bound one
    /// render, not the set.
    ///
    /// The cost is the decoded size, not the PNG's, for the reason this app
    /// already learned once: a count limit is not a memory limit, and
    /// `NSImage(data:)` holds the decoded bitmap.
    private let rendered: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    /// What one rendered page costs in memory: four bytes a pixel at the scale
    /// it was drawn.
    private static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh }
        return max(pixels, Int(image.size.width * image.size.height)) * 4
    }
    private(set) var sizes: [CGSize] = []

    /// Pages already asked for, so a `.task` that re-fires on scroll does not
    /// queue a second render of the same page.
    private var inFlight: Set<String> = []

    private let client = PDFRenderClient()

    /// Rendered at twice the layout width, so a Retina display has real pixels
    /// rather than an upscale. Higher costs helper time and memory for no
    /// visible gain.
    private static let renderScale: CGFloat = 2

    private func key(_ page: Int, _ width: CGFloat) -> String {
        // Bucketed to whole points: a fractional width change from a window
        // resize should not invalidate every page.
        "\(page)@\(Int(width.rounded()))"
    }

    /// Bumped whenever a page is stored, so the view has something observed to
    /// depend on.
    ///
    /// **An `NSCache` is invisible to `@Observable`.** This was a dictionary
    /// held in a `var`, so storing an image mutated an observed property and
    /// SwiftUI redrew. Bounding the memory meant moving to `NSCache`, whose
    /// `setObject` mutates the cache's own internals and nothing the observation
    /// machinery is watching — so every page rendered correctly, was cached
    /// correctly, and spun for ever, because nothing ever asked for it again.
    ///
    /// Found on a 10-page PDF that Safari opened without trouble.
    private var stored = 0

    func image(page: Int, width: CGFloat) -> NSImage? {
        // The read is the point: it registers this view's dependency on
        // `stored`, so the redraw happens when a page arrives. Written so it
        // cannot be mistaken for a leftover and deleted.
        guard stored >= 0 else { return nil }
        return rendered.object(forKey: key(page, width) as NSString)
    }

    /// Called when the download turns out to be a web page. The reader takes
    /// over and runs its normal extraction; this view says nothing, because a
    /// notice about a PDF would be wrong on a page that was never one.
    var onNotAPDF: () -> Void = { }

    /// The bytes the helper was given, kept so a helper that goes away can be
    /// handed the same document again.
    ///
    /// **An XPC service exiting is not a crash.** `ServiceType = Application`
    /// leaves the helper's lifetime to launchd, which reaps it when it has
    /// been idle — and the client's `interruptionHandler` cannot tell that
    /// from a PDFKit crash. Measured in this reader's own log: a document
    /// opened cleanly at 10:02:40 (13 pages from 44,371 bytes) and the
    /// connection was interrupted at 10:24:07, twenty-one minutes later,
    /// with no crash report for `PDFService` anywhere on the machine. The
    /// second event that day was "helper stopped while rendering page 6",
    /// which is the same thing noticed by somebody scrolling.
    ///
    /// So a lost helper is recovered from rather than reported. Held only
    /// while the document is on screen, which is the same lifetime the helper
    /// holds its own copy for.
    private var openedBytes: Data?

    /// Downloads, hands over, and reports what the helper found.
    func load(_ url: URL) async {
        state = .starting
        // An explicit retry gets a new helper. Without this, a client whose
        // deadline had fired stayed stopped for good and Try Again
        // re-downloaded the whole document only to fail before reaching XPC.
        client.reopen()
        do {
            let data = try await PDFDownload.fetch(url) { [weak self] got, total in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = self.state { return }
                    self.state = .downloading(received: got, total: total)
                }
            }
            let doc = try await client.open(data)
            guard doc.pageCount > 0 else {
                state = .failed("the document declares no pages")
                return
            }
            openedBytes = data
            sizes = doc.sizes
            jdnLog("pdf: helper opened \(doc.pageCount) page(s) from \(data.count) bytes")
            state = .ready(pageCount: doc.pageCount)
        } catch PDFDownload.Failure.notAPDF {
            onNotAPDF()
        } catch let failure as PDFRenderClient.Failure {
            jdnLog("pdf: \(failure.description)")
            state = .failed(failure.description)
        } catch {
            jdnLog("pdf: FAILED — \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Hand the same document to a new helper and draw the page again.
    ///
    /// Returns whether it worked. Once only: a document that kills two helpers
    /// in a row is a document, not an idle timeout, and saying so is then the
    /// right answer rather than an endless reconnection loop.
    private func reopenAndRetry(page: Int, width: CGFloat) async -> Bool {
        guard let bytes = openedBytes else { return false }
        jdnLog("pdf: the helper went away — handing the document to a new one")
        client.reopen()
        do {
            let doc = try await client.open(bytes)
            guard doc.pageCount > 0 else { return false }
            sizes = doc.sizes
            let image = try await client.render(page: page, width: width,
                                                scale: Self.renderScale)
            rendered.setObject(image, forKey: key(page, width) as NSString,
                               cost: Self.cost(of: image))
            stored &+= 1
            jdnLog("pdf: recovered — page \(page) drawn by the new helper")
            return true
        } catch {
            return false
        }
    }

    /// Renders one page, once.
    func render(page: Int, width: CGFloat) async {
        let k = key(page, width)
        guard rendered.object(forKey: k as NSString) == nil, !inFlight.contains(k) else { return }
        inFlight.insert(k)
        defer { inFlight.remove(k) }
        do {
            let image = try await client.render(page: page, width: width,
                                                scale: Self.renderScale)
            rendered.setObject(image, forKey: k as NSString, cost: Self.cost(of: image))
            stored &+= 1
        } catch let failure as PDFRenderClient.Failure {
            // A helper that has gone is usually launchd reclaiming an idle
            // one, not PDFKit falling over. Hand the same bytes to a new
            // helper and draw the page again; only say something if that
            // fails too.
            if case .helperStopped = failure, await reopenAndRetry(page: page, width: width) {
                return
            }
            if case .helperStopped = failure {
                jdnLog("pdf: helper stopped while rendering page \(page), "
                       + "and a second helper could not read the document either")
                state = .failed("the PDF helper stopped while reading this document")
            } else {
                jdnLog("pdf: page \(page) — \(failure.description)")
            }
        } catch {
            jdnLog("pdf: page \(page) — \(error.localizedDescription)")
        }
    }

    func close() { client.close() }
}

/// The download half, kept apart from the display half so each can be read on
/// its own. Every ceiling and every log line here was already in the app; this
/// is a move, not a rewrite.
enum PDFDownload {
    /// Its own session, so the transfer has a wall-clock bound and not only an
    /// idle one. The 42-second case below is comfortably inside this.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Long enough for a large report on a slow line — the one that prompted
    /// the progress work took 42 seconds for 7.4 MB — and short enough that a
    /// dead host does not hold the reader indefinitely.
    static let timeout: TimeInterval = 120
    /// How often to publish progress. Five times a second is smooth to watch
    /// and costs nothing against a download measured in minutes.
    static let reportEvery: TimeInterval = 0.2

    enum Failure: Error, CustomStringConvertible {
        case notWeb
        case http(Int)
        case tooBig(String)
        /// The URL ends in `.pdf` but the server sent a web page.
        ///
        /// GitHub is the case that found this: `…/blob/main/report.pdf` is an
        /// HTML page that *displays* a PDF, and the file itself lives on
        /// raw.githubusercontent.com. The reader routed on the extension,
        /// skipped the article extractor, and correctly reported that 237,303
        /// bytes of HTML were not a PDF — which is true and useless.
        ///
        /// The bytes are deliberately NOT carried. The reader re-runs its
        /// normal extraction, which is a five-rung ladder with WebKit fallbacks
        /// behind it; the only entry point that takes HTML directly is the
        /// first rung on its own. Saving one fetch by bypassing four rungs is
        /// the wrong trade, so the page is fetched again.
        case notAPDF
        var description: String {
            switch self {
            case .notWeb:          return "not a web address"
            case .http(let code):  return "HTTP \(code)"
            case .tooBig(let cap): return "larger than \(cap)"
            case .notAPDF:         return "the server sent a web page, not a PDF"
            }
        }
    }

    static func fetch(_ url: URL,
                      onProgress: @escaping (Int64, Int64) -> Void) async throws -> Data {
        // http(s) only, and this is the sink rather than a caller, so it asks
        // rather than trusting whoever built the URL. A `.pdf` extension on a
        // `file://` link would otherwise have read a local document straight
        // into the viewer.
        guard WebURL.isAllowed(url) else {
            jdnLog("pdf: refused \(url.scheme ?? "(no scheme)"): — not a web address")
            throw Failure.notWeb
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        // This sink does not go through BoundedFetch, so it installs the
        // redirect guard itself.
        let (stream, response) = try await Self.session.bytes(
            for: request, delegate: RedirectGuard())
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            jdnLog("pdf: \(url.host ?? "?") returned HTTP \(http.statusCode)")
            throw Failure.http(http.statusCode)
        }
        let total = response.expectedContentLength
        jdnLog("pdf: downloading \(url.lastPathComponent) — "
               + (total > 0 ? "\(total) bytes" : "size not declared"))

        let cap = ByteCountFormatter.string(fromByteCount: Int64(BoundedFetch.documentLimit),
                                            countStyle: .file)
        // A declared size over the ceiling is refused before the body is read.
        if total > Int64(BoundedFetch.documentLimit) {
            jdnLog("pdf: \(url.host ?? "?") declares \(total) bytes, over the \(cap) ceiling")
            throw Failure.tooBig(cap)
        }

        var data = Data()
        // Clamped to the ceiling. Reserving straight off the attacker's
        // `Content-Length` is how a 20 KB response asks for a gigabyte of
        // address space.
        if total > 0 { data.reserveCapacity(min(Int(total), BoundedFetch.documentLimit)) }
        var lastReport = Date()
        for try await byte in stream {
            data.append(byte)
            // A host that understates its length, or declares none at all, is
            // stopped here instead.
            if data.count > BoundedFetch.documentLimit {
                jdnLog("pdf: \(url.host ?? "?") went past the \(cap) ceiling — abandoned")
                throw Failure.tooBig(cap)
            }
            // Report on a timer, not per byte: a 7.4 MB file is 7.4 million
            // iterations and a state write on each would cost far more than
            // the download.
            if Date().timeIntervalSince(lastReport) > reportEvery {
                lastReport = Date()
                onProgress(Int64(data.count), total)
            }
        }

        // Trust the bytes, not the path. `ArticleExtractor` already does the
        // mirror image of this — a PDF served without a `.pdf` extension — by
        // testing the Content-Type and the `%PDF` magic number, and
        // `PDFContentType` is that same test read the other way round so the
        // two cannot disagree.
        let declared = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        if PDFContentType.isWebPage(bytes: data, declaredType: declared) {
            jdnLog("pdf: \(url.host ?? "?") sent \(declared ?? "no type") for a .pdf path — "
                   + "handing back to the article extractor")
            throw Failure.notAPDF
        }
        return data
    }
}

/// The page list. One image per page, fetched when the page comes into view.
struct IsolatedPDFPages: View {
    @State var model: IsolatedPDFModel
    let pageCount: Int
    /// 1.0 fits the pane's width. Zoom multiplies it, and the helper re-renders.
    @Binding var zoom: CGFloat

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        let width = max(80, (geo.size.width - 24) * zoom)
                        let height = pageHeight(index, width: width)
                        ZStack {
                            if let image = model.image(page: index, width: width) {
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: width, height: height)
                            } else {
                                // Sized from the page's own dimensions, so the
                                // scroll view's extent is right before any page
                                // is drawn and the bar does not jump as pages
                                // arrive.
                                Rectangle()
                                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                                    .frame(width: width, height: height)
                                    .overlay(ProgressView().controlSize(.small))
                            }
                        }
                        .task(id: "\(index)@\(Int(width.rounded()))") {
                            await model.render(page: index, width: width)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// The page's height at a given width, from the size the helper reported.
    /// Falls back to A4's ratio for a page whose size did not come through.
    private func pageHeight(_ index: Int, width: CGFloat) -> CGFloat {
        guard index < model.sizes.count else { return width * 1.414 }
        let size = model.sizes[index]
        // Checked here as well as at both ends of the XPC reply: this is the
        // value that becomes a frame height, and a `/MediaBox` written with
        // 400 digits parses to a finite 1e75 — about 7e119 at a 700 pt pane.
        guard PDFPageSizes.isUsable(size) else { return width * 1.414 }
        return width * (size.height / size.width)
    }
}
