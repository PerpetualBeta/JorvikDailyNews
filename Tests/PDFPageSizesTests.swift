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

        T.suite("PDF page sizes: geometry a layout cannot be asked for") {
            // The PNG half of the helper's reply was checked carefully on
            // arrival and commented at length; the geometry half went straight
            // into a frame. A `/MediaBox` height written with about 400 digits
            // parses, and `bounds(for: .cropBox).size` returns a finite 1e75 —
            // about 7e119 as a frame height at a 700 pt pane.
            T.expect(PDFPageSizes.isUsable(CGSize(width: 612, height: 792)), "US Letter is fine")
            T.expect(PDFPageSizes.isUsable(CGSize(width: 14_400, height: 14_400)),
                     "and so is PDF's own largest page")
            T.expect(!PDFPageSizes.isUsable(CGSize(width: 612, height: 1e75)), "1e75 is not")
            T.expect(!PDFPageSizes.isUsable(CGSize(width: CGFloat.infinity, height: 792)),
                     "nor is infinity")
            T.expect(!PDFPageSizes.isUsable(CGSize(width: CGFloat.nan, height: 792)), "nor a NaN")
            T.expect(!PDFPageSizes.isUsable(CGSize(width: -612, height: 792)),
                     "nor a negative side")

            // Replaced rather than dropped, because `.zero` is the value the
            // viewer already reads as "no size given" and falls back on.
            let out = PDFPageSizes.unflatten([612, 792, 612, 1e75, 595, 842])
            T.equal(out.count, 3, "every page still has an entry")
            T.equal(out[0], CGSize(width: 612, height: 792), "the honest ones are untouched")
            T.equal(out[1], .zero, "the absurd one becomes no size at all")
            T.equal(out[2], CGSize(width: 595, height: 842), "and the page after it survives")
        }
    }
}
