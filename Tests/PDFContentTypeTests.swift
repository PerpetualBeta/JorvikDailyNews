import Foundation

/// Every case here comes from the link that found the bug, or from the ones the
/// fix must not break.
enum PDFContentTypeTests {

    private static func pdf(_ extra: String = "") -> Data {
        Data("%PDF-1.4\n\(extra)".utf8)
    }
    private static func html() -> Data {
        Data("\n\n\n\n  \n\n<!DOCTYPE html>\n<html lang=\"en\">".utf8)
    }

    static func run() {
        T.suite("PDF routing: a .pdf path that serves a web page") {
            // GitHub's blob viewer, verbatim in shape: 237,303 bytes of HTML
            // behind a URL ending .pdf, declared text/html.
            T.expect(PDFContentType.isWebPage(bytes: html(),
                                              declaredType: "text/html; charset=utf-8"),
                     "GitHub's blob page goes to the extractor")
            T.expect(PDFContentType.isWebPage(bytes: html(),
                                              declaredType: "application/xhtml+xml"),
                     "so does XHTML")
            T.expect(PDFContentType.isWebPage(bytes: html(), declaredType: "TEXT/HTML"),
                     "the header's case does not matter")
        }

        T.suite("PDF routing: the magic number overrules the header") {
            // A real PDF mislabelled as HTML must still be read as a PDF. The
            // first four bytes are not a matter of opinion.
            T.expect(!PDFContentType.isWebPage(bytes: pdf(),
                                               declaredType: "text/html; charset=utf-8"),
                     "a real PDF declared text/html is still a PDF")
            T.expect(!PDFContentType.isWebPage(bytes: pdf(), declaredType: "application/pdf"),
                     "and an honestly declared one obviously is")
        }

        T.suite("PDF routing: an unhelpful header is not evidence of HTML") {
            // raw.githubusercontent.com sends application/octet-stream for the
            // very PDF this bug was found with. Guessing HTML from a vague or
            // missing header would send real PDFs to the extractor, which is
            // worse than the failure being fixed.
            for declared in ["application/octet-stream", "binary/octet-stream",
                             "application/download", "", "text/plain"] {
                T.expect(!PDFContentType.isWebPage(bytes: pdf(), declaredType: declared),
                         "octet-stream and friends: \(declared.isEmpty ? "(empty)" : declared)")
            }
            T.expect(!PDFContentType.isWebPage(bytes: pdf(), declaredType: nil),
                     "no header at all")
            // Bytes that are neither, with no claim of HTML, stay with the
            // viewer so its own "not readable as a PDF" remains the backstop.
            T.expect(!PDFContentType.isWebPage(bytes: Data([0x00, 0x01, 0x02, 0x03]),
                                               declaredType: "application/octet-stream"),
                     "unreadable bytes with no HTML claim stay with the viewer")
            T.expect(!PDFContentType.isWebPage(bytes: Data(), declaredType: nil),
                     "no bytes at all")
        }

        T.suite("PDF routing: the magic number is exact") {
            T.equal(PDFContentType.magic.count, 4, "four bytes")
            T.expect(!PDFContentType.isWebPage(bytes: Data("%PDF".utf8), declaredType: "text/html"),
                     "exactly the magic number and nothing else")
            // A near miss is not a PDF: lowercase, or one byte short.
            T.expect(PDFContentType.isWebPage(bytes: Data("%pdf-1.4".utf8), declaredType: "text/html"),
                     "lowercase %pdf is not the magic number")
            T.expect(PDFContentType.isWebPage(bytes: Data("%PD".utf8), declaredType: "text/html"),
                     "three bytes is not the magic number")
            // A PDF preceded by junk does not start with the magic number, so
            // it is not treated as one. Recorded because it is a real shape —
            // some servers prepend a BOM or a blank line — and because the
            // viewer's own message is then the right answer, not this one.
            T.expect(PDFContentType.isWebPage(bytes: Data("\u{FEFF}%PDF-1.4".utf8),
                                              declaredType: "text/html"),
                     "a BOM before %PDF means the bytes do not start with it")
        }
    }
}
