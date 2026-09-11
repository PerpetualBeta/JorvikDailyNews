import Foundation

/// The wire format for page sizes.
///
/// It is a flat list of numbers rather than `[NSValue]` because NSXPC only lets
/// a default set of classes through a reply and `NSValue` is not one of them.
/// That failure is silent on the helper's side — it read the bytes, parsed the
/// document, built the sizes and returned from the reply block — and arrives at
/// the client as `NSXPCConnectionInterrupted`, which reads like a crash.
enum PDFPageSizesTests {
    static func run() {
        T.suite("PDF page sizes: the flat wire format") {
            let a4 = CGSize(width: 595, height: 842)
            let letter = CGSize(width: 612, height: 792)
            T.equal(PDFPageSizes.flatten([letter]), [612, 792], "one page flattens to two numbers")
            T.equal(PDFPageSizes.flatten([a4, letter]), [595, 842, 612, 792], "two pages, four numbers")
            T.equal(PDFPageSizes.flatten([]), [], "no pages, no numbers")

            let round = PDFPageSizes.unflatten(PDFPageSizes.flatten([a4, letter]))
            T.equal(round.count, 2, "round trip keeps the count")
            T.equal(round.first, a4, "and the first page")
            T.equal(round.last, letter, "and the last")
        }

        T.suite("PDF page sizes: a malformed list loses pages, not the document") {
            // A short or odd list yields what it can. A missing size costs a
            // placeholder of the wrong height; refusing the document would cost
            // the whole PDF.
            T.equal(PDFPageSizes.unflatten([]), [], "empty")
            T.equal(PDFPageSizes.unflatten([612]), [], "a single number is not a size")
            T.equal(PDFPageSizes.unflatten([612, 792, 595]).count, 1,
                    "an odd trailing number is dropped")
            T.equal(PDFPageSizes.unflatten([612, 792, 595, 842]).count, 2, "an even list is whole")
            T.equal(PDFPageSizes.unflatten([0, 0]), [CGSize(width: 0, height: 0)],
                    "a zero size survives, for the viewer to fall back on")
        }
    }
}
