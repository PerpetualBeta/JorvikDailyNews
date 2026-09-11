import Foundation

/// The only thing the app and the PDF helper agree on.
///
/// **Why this exists.** A feed controls the bytes of a linked PDF and also
/// chooses that PDFKit is what parses them, because routing is extension-driven.
/// PDFKit is a large C/C++ parser with a long CVE history, and until now it ran
/// in the app's own process, reachable from one click on a headline. The App
/// Sandbox (1.4.8) confined the damage to the container; it did not stop a
/// memory-safety bug in PDFKit from being a memory-safety bug in Jorvik Daily
/// News. Moving the parse into a helper makes a crash a crash of the helper.
///
/// The helper never sees a URL and never opens a file by path. It is handed a
/// read-only file descriptor for bytes the app has already fetched, so it needs
/// no network and no file-system access of its own, and its entitlements grant
/// neither. What comes back is pixels and plain text, never a `PDFDocument`:
/// handing back a parsed object would put the parse back in the app.
@objc public protocol PDFRenderServiceProtocol {

    /// Parses the bytes and reports what is there, without rendering anything.
    ///
    /// - Parameter handle: read end of a file holding the PDF. The app closes
    ///   its own copy after sending; the descriptor keeps the bytes alive even
    ///   though the path is unlinked immediately.
    /// - Parameter reply: page count, page sizes in PDF points as a flat list
    ///   of width, height, width, height…, and a reason when the bytes are not
    ///   a PDF.
    ///
    /// **The sizes are plain numbers on purpose.** The obvious shape is
    /// `[NSValue]` wrapping `CGSize`, and it cost an afternoon: NSXPC only lets
    /// a default set of classes through a reply, `NSValue` is not one of them,
    /// and the failure is silent on the service side. It read the bytes,
    /// parsed the document, built the sizes and returned from the reply block
    /// quite happily; the client got `NSXPCConnectionInterrupted` and the
    /// helper vanished. `NSNumber` is in the default set, so a flat array of
    /// numbers needs no allow-listing and cannot fail this way.
    func open(handle: FileHandle,
              reply: @escaping (_ pageCount: Int, _ sizes: [Double], _ failure: String?) -> Void)

    /// One page, rendered to PNG at the requested scale.
    ///
    /// PNG rather than a bitmap because the payload crosses a process boundary
    /// and its size should not be the page area times four bytes.
    func render(page: Int, width: Double, scale: Double,
                reply: @escaping (_ png: Data?, _ failure: String?) -> Void)

    /// A page's text, for search and for copying. Plain text carries no
    /// structure a renderer could act on, so this is the one thing other than
    /// pixels worth passing back.
    func text(page: Int, reply: @escaping (_ text: String?) -> Void)
}

/// The page-size wire format, kept next to the protocol that defines it so the
/// two ends cannot drift.
public enum PDFPageSizes {
    /// Most pages a document may declare.
    ///
    /// `open` walks every page's crop box before replying and the reply is two
    /// doubles per page, so a small file declaring an enormous page tree is an
    /// amplification at both ends. The largest opened during development was
    /// 154 pages. Here rather than in the helper because the client checks the
    /// same number on the way back in.
    public static let maxPages = 5_000

    /// Largest side a page may declare, in points.
    ///
    /// PDF's own maximum page is 14,400 points — 200 inches — so this is
    /// comfortably above anything a real document carries. It exists because
    /// a `/MediaBox` height written with about 400 digits parses, and
    /// `bounds(for: .cropBox).size` then returns a finite 1e75. At a 700 pt
    /// pane that is about 7e119 as a frame height inside a `LazyVStack`.
    /// (1e305 is not valid PDF real syntax: `PDFDocument(url:)` returns nil,
    /// so a non-finite size is not reachable this way. Tested for anyway,
    /// because both ends of this check exist to not trust the other one.)
    public static let maxPageSide: Double = 20_000

    /// Whether a declared page size is one a layout can be asked for.
    public static func isUsable(_ size: CGSize) -> Bool {
        let w = Double(size.width), h = Double(size.height)
        return w.isFinite && h.isFinite && w > 0 && h > 0
            && w <= maxPageSide && h <= maxPageSide
    }

    /// Rebuilds page sizes from the flat width, height, width, height… list.
    ///
    /// A short or odd-length list yields the pairs it can and drops the
    /// remainder. A missing size costs a placeholder of the wrong height and
    /// nothing worse, which is a better failure than refusing the document.
    ///
    /// **A size that is not usable becomes `.zero`, which is the same "no
    /// size" the caller already handles.** The PNG half of the helper's reply
    /// is checked carefully on arrival and commented at length; the geometry
    /// half was passed straight to the model and into a frame. Checked at both
    /// ends: the helper will not send one, and a compromised helper cannot
    /// make the client draw one.
    public static func unflatten(_ flat: [Double]) -> [CGSize] {
        guard flat.count >= 2 else { return [] }
        return stride(from: 0, to: flat.count - 1, by: 2).map {
            let size = CGSize(width: flat[$0], height: flat[$0 + 1])
            return isUsable(size) ? size : .zero
        }
    }

    /// The inverse, which is what the helper sends.
    public static func flatten(_ sizes: [CGSize]) -> [Double] {
        sizes.flatMap { [Double($0.width), Double($0.height)] }
    }
}

/// Service name, which is the helper bundle's identifier. One constant so the
/// app, the helper's Info.plist and the build rule cannot drift apart.
public let pdfRenderServiceName = "cc.jorviksoftware.JorvikDailyNews.PDFService"
