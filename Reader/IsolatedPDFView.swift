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
    private var rendered: [String: NSImage] = [:]
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

    func image(page: Int, width: CGFloat) -> NSImage? {
        rendered[key(page, width)]
    }

    /// Called when the download turns out to be a web page. The reader takes
    /// over and runs its normal extraction; this view says nothing, because a
    /// notice about a PDF would be wrong on a page that was never one.
    var onNotAPDF: () -> Void = { }

    /// Downloads, hands over, and reports what the helper found.
    func load(_ url: URL) async {
        state = .starting
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

    /// Renders one page, once.
    func render(page: Int, width: CGFloat) async {
        let k = key(page, width)
        guard rendered[k] == nil, !inFlight.contains(k) else { return }
        inFlight.insert(k)
        defer { inFlight.remove(k) }
        do {
            rendered[k] = try await client.render(page: page, width: width,
                                                  scale: Self.renderScale)
        } catch let failure as PDFRenderClient.Failure {
            // A helper that has died takes the whole document with it, and the
            // reader must say so rather than leaving grey rectangles.
            if case .helperStopped = failure {
                jdnLog("pdf: helper stopped while rendering page \(page)")
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
        let (stream, response) = try await URLSession.shared.bytes(
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
        guard size.width > 0, size.height > 0 else { return width * 1.414 }
        return width * (size.height / size.width)
    }
}
