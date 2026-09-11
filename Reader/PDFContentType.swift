import Foundation

/// Decides whether bytes fetched from a `.pdf` path are actually a PDF.
///
/// Its own file, with nothing but Foundation in it, so the suite can test the
/// decision without a screen or a network. The bug that produced it was not in
/// the fetching — that worked perfectly — it was in believing a file extension.
enum PDFContentType {

    /// The four bytes every PDF starts with.
    static let magic = Data([0x25, 0x50, 0x44, 0x46])   // %PDF

    /// True when the response should go to the article extractor instead of the
    /// PDF viewer.
    ///
    /// **The magic number wins.** A server that mislabels a real PDF as
    /// `text/html` still gets read as a PDF, because the first four bytes are
    /// not a matter of opinion, whereas a Content-Type header is whatever the
    /// server felt like sending. Only when the bytes are *not* a PDF does the
    /// declared type get a say.
    ///
    /// **An unhelpful or absent type is not evidence of HTML.** Plenty of hosts
    /// send `application/octet-stream` for a PDF — the raw GitHub URL in the
    /// report that found this bug does exactly that. So this returns false
    /// unless the server positively claims HTML, and the viewer's own "not
    /// readable as a PDF" message remains the backstop for everything else.
    /// Guessing HTML from a missing header would send real PDFs to the
    /// extractor, which is a worse failure than the one being fixed.
    static func isWebPage(bytes: Data, declaredType: String?) -> Bool {
        guard !bytes.starts(with: magic) else { return false }
        let declared = (declaredType ?? "").lowercased()
        return declared.contains("text/html") || declared.contains("application/xhtml")
    }
}
