import Foundation

/// The rule that stops one photograph appearing several times on one page.
///
/// The case that prompted it: the paper of 9 September 2026 carried thirteen
/// arXiv papers, every one of them declaring the same `arxiv-logo-fb.png`, and
/// three copies of Apple's iPhone Duo hero under three different URLs.
enum PagePicturesTests {

    static func run() {
        T.suite("Repeat by address") {
            // The arXiv case: one URL, many stories. No fingerprint needed.
            let logo = "https://arxiv.org/static/browse/0.3.4/images/arxiv-logo-fb.png"
            let page = (1...5).map { item("paper \($0)", image: logo) }
            let out = PagePictures.repeats(in: page, signature: { _ in nil })
            T.equal(out.count, 4, "four of five lose the picture")
            T.expect(!out.contains("paper 1"), "the first keeps it")
            T.expect(out.contains("paper 5"), "the last does not")
        }

        T.suite("Different pictures are left alone") {
            let page = (1...5).map { item("story \($0)", image: "https://example.com/\($0).jpg") }
            T.expect(PagePictures.repeats(in: page, signature: { _ in nil }).isEmpty,
                     "five different addresses, nothing suppressed")
        }

        T.suite("Items with no picture are ignored") {
            let page = [item("a", image: nil), item("b", image: nil),
                        item("c", image: "https://example.com/x.jpg")]
            T.expect(PagePictures.repeats(in: page, signature: { _ in nil }).isEmpty,
                     "a card with no picture cannot repeat one")
        }

        T.suite("Repeat by appearance, not address") {
            // The Apple case: three URLs, one photograph. Nothing about the
            // addresses says so.
            let a = URL(string: "https://www.apple.com/v/iphone-duo/a/images/meta/og.png")!
            let b = URL(string: "https://store.storeimages.cdn-apple.com/1/iphone-duo-fi.jpg")!
            let c = URL(string: "https://www.apple.com/newsroom/images/2026/09/tile/Ap.jpg")!
            let page = [item("duo", image: a.absoluteString),
                        item("pricing", image: b.absoluteString),
                        item("unveils", image: c.absoluteString)]
            // Distances taken from the real files: 4 bits apart and 6 bits
            // apart from the first, and 8 apart from each other.
            let sigs: [URL: PictureSignature] = [
                a: sig(edges: 0x0000_0000_0000_0000, grey: 100),
                b: sig(edges: 0x0000_0000_0000_000F, grey: 104),   // 4 bits
                c: sig(edges: 0x0000_0000_0000_00F0, grey: 106)    // 4 bits from a, 8 from b
            ]
            let out = PagePictures.repeats(in: page, signature: { sigs[$0] })
            T.equal(out.count, 2, "two of three lose the picture")
            T.expect(!out.contains("duo"), "the first keeps it")
        }

        T.suite("A chain collapses even when the ends do not match") {
            // The reason a candidate is compared against every picture SEEN on
            // the page rather than only those kept.
            //
            // The middle one matches the first, so it is dropped. The last one
            // matches the MIDDLE but is beyond threshold from the first, so
            // comparing only against what was kept would keep it — and the
            // page would still be showing the same photograph twice. The real
            // Apple trio behaves exactly like this: 4 and 6 bits from the
            // first copy, 8 bits from each other.
            let a = URL(string: "https://example.com/a.jpg")!
            let b = URL(string: "https://example.com/b.jpg")!
            let c = URL(string: "https://example.com/c.jpg")!
            let sigs: [URL: PictureSignature] = [
                a: sig(edges: 0x0000_0000_0000_0000, grey: 100),
                b: sig(edges: 0x0000_0000_0000_003F, grey: 100),   // 6 from a
                c: sig(edges: 0x0000_0000_0000_0FFF, grey: 100)    // 6 from b, 12 from a
            ]
            T.equal(sigs[a]!.edgeDistance(to: sigs[b]!), 6, "the middle matches the first")
            T.equal(sigs[b]!.edgeDistance(to: sigs[c]!), 6, "and the last matches the middle")
            T.expect(sigs[a]!.edgeDistance(to: sigs[c]!) > PictureSignature.maxEdgeDistance,
                     "but the two ends are beyond threshold from each other")
            let page = [item("first", image: a.absoluteString),
                        item("second", image: b.absoluteString),
                        item("third", image: c.absoluteString)]
            let out = PagePictures.repeats(in: page, signature: { sigs[$0] })
            T.equal(out.count, 2, "both later copies go")
            T.expect(!out.contains("first"), "the first keeps its picture")
        }

        T.suite("Colour must agree as well as structure") {
            // The measured false positive this half exists to stop: Apple's
            // logo tile and an AirPods tile are 7 bits apart on structure —
            // inside the threshold — and 41 apart on colour.
            let a = URL(string: "https://example.com/logo.jpg")!
            let b = URL(string: "https://example.com/airpods.jpg")!
            let sigs: [URL: PictureSignature] = [
                a: sig(edges: 0x0000_0000_0000_007F, grey: 40),
                b: sig(edges: 0x0000_0000_0000_0000, grey: 200)    // 7 bits, far apart in tone
            ]
            T.equal(sigs[a]!.edgeDistance(to: sigs[b]!), 7, "structure alone would match")
            T.expect(sigs[a]!.colourDistance(to: sigs[b]!) > PictureSignature.maxColourDistance,
                     "colour keeps them apart")
            let page = [item("logo", image: a.absoluteString), item("airpods", image: b.absoluteString)]
            T.expect(PagePictures.repeats(in: page, signature: { sigs[$0] }).isEmpty,
                     "so neither picture is suppressed")
        }

        T.suite("Identical signatures are the same picture") {
            let s = sig(edges: 0xDEAD_BEEF_CAFE_F00D, grey: 128)
            T.equal(s.edgeDistance(to: s), 0, "no distance from itself")
            T.equal(s.colourDistance(to: s), 0, "nor in colour")
            T.expect(s.isSamePicture(as: s), "and it matches itself")
        }

        T.suite("An unknown fingerprint falls back to the address") {
            // Until a picture has been downloaded once there is nothing to
            // compare, and the rule must not guess.
            let page = [item("a", image: "https://example.com/1.jpg"),
                        item("b", image: "https://example.com/2.jpg")]
            T.expect(PagePictures.repeats(in: page, signature: { _ in nil }).isEmpty,
                     "no fingerprints, no perceptual matches")
        }
    }

    // MARK: - Helpers

    /// A signature with a chosen edge hash and a flat grey field, so a test
    /// can move one axis at a time.
    private static func sig(edges: UInt64, grey: UInt8) -> PictureSignature {
        let cells = PictureSignature.colourSide * PictureSignature.colourSide * 3
        return PictureSignature(edges: edges, colour: [UInt8](repeating: grey, count: cells))
    }

    private static func item(_ id: String, image: String?) -> FeedItem {
        FeedItem(feedId: UUID(), itemId: id, title: id,
                 link: URL(string: "https://example.com/\(id.replacingOccurrences(of: " ", with: "-"))")!,
                 summary: "A standfirst.", imageURL: image.flatMap(URL.init(string:)),
                 publishedAt: Date(), section: "News", sourceTitle: "fixture")
    }
}

/// A picture with nothing in it decodes perfectly, so pixels are the only
/// thing that can tell. `https://s0.wp.com/i/blank.jpg` is WordPress's
/// placeholder `og:image` and took the lead slot on 10 September 2026.
enum BlankPictureTests {

    static func run() {
        T.suite("Blank: one flat colour has nothing in it") {
            T.expect(flat(255).isFeatureless, "white")
            T.expect(flat(0).isFeatureless, "black")
            T.expect(flat(128).isFeatureless, "mid grey")
            T.equal(flat(200).colourSpread, 0, "a flat field has no spread")
        }

        T.suite("Blank: a real picture is not") {
            // The weakest of the 47 real hero images measured 6 edge bits and
            // 23 colour spread. Both thresholds sit well below that.
            let weakest = PictureSignature(
                edges: 0x0000_0000_0000_003F,        // 6 bits
                colour: grid(base: 128, extreme: 128 + 23))
            T.equal(weakest.edges.nonzeroBitCount, 6, "6 edge bits, as measured")
            T.equal(weakest.colourSpread, 23, "23 spread, as measured")
            T.expect(!weakest.isFeatureless, "so the weakest real picture survives")
        }

        T.suite("Blank: structure alone is enough to save it") {
            // Detail but no colour variation — a line drawing on white.
            let drawing = PictureSignature(edges: 0x0F0F_0F0F_0F0F_0F0F,
                                           colour: grid(base: 250, extreme: 250))
            T.equal(drawing.colourSpread, 0, "no colour variation at all")
            T.expect(!drawing.isFeatureless, "but it plainly has something drawn on it")
        }

        T.suite("Blank: colour alone is enough to save it") {
            // A smooth gradient: no hard edges, but plenty of colour.
            let gradient = PictureSignature(edges: 0, colour: grid(base: 60, extreme: 200))
            T.equal(gradient.edges.nonzeroBitCount, 0, "no edges")
            T.expect(!gradient.isFeatureless, "a gradient is still a picture")
        }

        T.suite("Blank: the thresholds leave real headroom") {
            T.expect(PictureSignature.maxBlankEdgeBits < 6,
                     "below the fewest edge bits any real picture showed")
            T.expect(PictureSignature.maxBlankColourSpread < 23,
                     "below the smallest colour spread any real picture showed")
        }
    }

    private static func flat(_ v: UInt8) -> PictureSignature {
        PictureSignature(edges: 0, colour: grid(base: v, extreme: v))
    }

    /// A colour grid that is `base` everywhere except one cell.
    private static func grid(base: UInt8, extreme: UInt8) -> [UInt8] {
        let n = PictureSignature.colourSide * PictureSignature.colourSide * 3
        var out = [UInt8](repeating: base, count: n)
        out[0] = extreme
        return out
    }
}
