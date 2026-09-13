import Foundation

/// Time bounds on the scans a page chooses the size of.
///
/// **Every one of these was `<tag\b[^>]*>` run over a whole document.** With
/// no `>` after the opener ICU walks the character class to end of input and
/// backtracks a character at a time, from every position the opener appears
/// at. Nothing stops one once it starts: `NSRegularExpression` never polls
/// `Task.isCancelled`, so the refresh watchdog's `work.cancel()` leaves the
/// thread spinning for the life of the process, and the reader's main-actor
/// backstop cannot run while the main actor is inside the match.
///
/// These assert a real time bound rather than completion. A suite that only
/// asserts the call returned is how the last one of these survived two
/// reviews: `Tests/StandfirstTests.swift` ended with `T.expect(true, "16 KB of
/// each unclosed opener completes")`, an unconditional pass.
enum QuadraticTests {

    /// Generous enough not to be flaky on a loaded machine, and far below the
    /// seconds-to-minutes these cost before. The quadratic versions measured
    /// 27.9 s, 44.8 s and 201.8 s on the same inputs.
    private static let budget: TimeInterval = 2.0

    private static func timed(_ what: String, _ body: () -> Void) {
        let started = Date()
        body()
        let took = Date().timeIntervalSince(started)
        T.expect(took < budget, "\(what) took \(String(format: "%.2f", took))s, budget \(budget)s")
    }

    static func run() async {
        T.suite("Quadratic: the tag splitter skips a window it cannot close") {
            // 128 KB of openers with no `>` anywhere. The pattern this
            // replaced measured 27.9 s on exactly this shape.
            let bomb = String(repeating: "<link ", count: 128 * 1024 / 6)
            timed("splitting 128 KB of unclosed <link") {
                T.equal(HTMLTags.named("link", in: bomb).count, 0, "and finds no tag")
            }
            let frames = String(repeating: "<iframe ", count: 128 * 1024 / 8)
            timed("splitting 128 KB of unclosed <iframe") {
                T.equal(HTMLTags.named("iframe", in: frames).count, 0, "and finds no frame")
            }
            // Doubling the input must not quadruple the time.
            let bigger = String(repeating: "<link ", count: 512 * 1024 / 6)
            timed("splitting 512 KB of unclosed <link") {
                _ = HTMLTags.named("link", in: bigger)
            }
        }

        T.suite("Quadratic: the splitter still finds real tags") {
            let page = "<html><head><title>A</title>"
                + "<link rel=\"alternate\" type=\"application/rss+xml\" href=\"/feed.xml\">"
                + "<link rel=\"stylesheet\" href=\"/a.css\">"
                + "</head><body><iframe src=\"https://www.youtube.com/embed/abc\"></iframe></body></html>"
            T.equal(HTMLTags.named("link", in: page).count, 2, "both link tags")
            T.equal(HTMLTags.named("iframe", in: page).count, 1, "and the frame")
            T.expect(HTMLTags.named("link", in: page).first?.contains("rss+xml") == true,
                     "with their attributes intact")

            // And discovery still reads a feed out of a real page.
            let found = FeedDiscovery().parseLinkTags(
                in: page, baseURL: URL(string: "https://example.com/index.html")!)
            T.equal(found.count, 1, "one feed discovered")
            T.equal(found.first?.url.absoluteString, "https://example.com/feed.xml",
                    "resolved against the page")
        }

        // Measured before the suite, because `T.suite` takes a synchronous
        // closure and these have to await.
        //
        // `withTaskGroup` does not return until every child completes, so
        // `group.cancelAll()` bounds nothing when the losing child is not
        // cancellation-aware — and `await someTask.value` on a
        // `Task<T, Never>` is exactly that. Measured before the fix: the
        // watchdog fired at 2.07 s and the group returned at 10.23 s, so
        // `isRefreshing = false` ran only once the hang had ended.
        let slowStart = Date()
        let slow = Task { @MainActor () -> Bool in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        let abandoned = await FirstAnswer.of(0.5, fallback: false) {
            _ = await slow.value
            return true
        }
        let waited = Date().timeIntervalSince(slowStart)
        slow.cancel()
        let quick = await FirstAnswer.of(5, fallback: false) { true }
        var fallbacks = 0
        for _ in 0..<200 {
            if await FirstAnswer.of(0.001, fallback: false, work: { true }) == false { fallbacks += 1 }
        }

        T.suite("Races: the deadline abandons rather than waiting") {
            T.expect(!abandoned, "the deadline wins against a stuck worker")
            T.expect(waited < 1.5, "and returns at the deadline, not at the worker "
                     + "(\(String(format: "%.2f", waited))s)")
            T.expect(quick, "a worker that answers first is not replaced by the fallback")
            T.expect(fallbacks <= 200, "200 tight races complete without a double resume")
        }

        T.suite("Tags: the splitter's edges") {
            // Shared by four call sites now, so a fault here is systemic.
            T.expect(HTMLTags.named("link", in: "").isEmpty, "empty input")
            T.expect(HTMLTags.named("link", in: "<p>hello</p>").isEmpty, "no tags")
            T.equal(HTMLTags.named("link", in: "<LINK REL=x>").count, 1, "case insensitive")
            T.expect(HTMLTags.named("link", in: "abc<link").isEmpty, "an opener with no close")
            T.equal(HTMLTags.named("link", in: "<link a><link b>").count, 2, "two tags")
            // A tag name ends at whitespace, `/` or `>`.
            T.expect(HTMLTags.named("link", in: "<linkedin a>").isEmpty, "<linkedin> is not <link>")
            T.expect(HTMLTags.named("meta", in: "<metadata x=1>").isEmpty, "<metadata> is not <meta>")
            T.equal(HTMLTags.named("br", in: "<br/>").count, 1, "a self-closing tag")
            T.equal(HTMLTags.named("hr", in: "<hr>").count, 1, "and a bare one")
            // The window skip must not end the scan.
            let longTag = "<link " + String(repeating: "x", count: 5000) + "><link ok>"
            T.expect(!HTMLTags.named("link", in: longTag).isEmpty,
                     "an over-long tag does not stop the scan")
            let many = String(repeating: "<link a>", count: 1000)
            T.equal(HTMLTags.named("link", in: many).count, HTMLTags.maxTags, "the count is capped")
            T.equal(HTMLTags.named("link", in: many, limit: 10).count, 10, "and the cap is settable")
        }

        T.suite("Clamping: the ceiling's edges") {
            T.equal("hello".clamped(toUTF16: 10), "hello", "under the limit is untouched")
            T.equal("hello".clamped(toUTF16: 5), "hello", "exactly the limit")
            T.expect("hello".clamped(toUTF16: 0).isEmpty, "a zero limit")
            T.expect("hello".clamped(toUTF16: -1).isEmpty, "a negative limit")
            T.expect("".clamped(toUTF16: 10).isEmpty, "an empty string")

            // Astral characters are two UTF-16 units, so an odd limit must cut
            // short rather than split the pair.
            let emoji = String(repeating: "\u{1F600}", count: 10)
            T.equal(emoji.clamped(toUTF16: 5).utf16.count, 4, "an odd limit cuts to a scalar")
            T.equal(emoji.clamped(toUTF16: 6).utf16.count, 6, "an even one is exact")
            T.expect(emoji.clamped(toUTF16: 5).unicodeScalars
                        .allSatisfy { $0.value < 0xD800 || $0.value > 0xDFFF },
                     "and never leaves a lone surrogate")

            let cluster = "a" + String(repeating: "\u{0301}", count: 200)
            let clusters = String(repeating: cluster, count: 100)
            T.equal(clusters.storedLength, clusters.utf16.count, "storedLength is UTF-16")
            T.expect(clusters.clamped(toUTF16: 100).utf16.count <= 100,
                     "a cluster is measured in UTF-16, not counted as one")
        }

        T.suite("Quadratic: discovery is bounded on a hostile body") {
            // The body `fetchSelfHealing` would hand it after one empty 200.
            let bomb = String(repeating: "<link ", count: 128 * 1024 / 6)
            timed("discovering links in 128 KB of openers") {
                let out = FeedDiscovery().parseLinkTags(
                    in: bomb, baseURL: URL(string: "https://example.com/")!)
                T.equal(out.count, 0, "and finds nothing")
            }
        }

        T.suite("Quadratic: a picture decoder is chosen by us, not by the feed") {
            // ImageIO decides which parser runs from the BYTES, and the feed
            // chooses the bytes. CGImageSourceCopyTypeIdentifiers() returns 62
            // UTIs on this machine, and CoreGraphics reaches PDF through a
            // further fallback that is not even in that list — so a feed could
            // answer a picture URL with PDF, DICOM, PICT, OpenEXR, DDS or any
            // of 25 camera RAW parsers and pick which one ran, in the process
            // that holds the network entitlement, on the hourly path.
            //
            // Verified against the real thing: ImageIO reads a PDF as
            // com.adobe.pdf with 10 pages and publishes NO pixel dimensions,
            // so the 40,000px / 80-megapixel guard passed on 0x0 and the
            // thumbnail request became the full maxPixelSize.
            let pdf = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8)
            T.expect(!ImageCache.isAcceptedPicture(pdf), "PDF bytes are refused")

            for (what, bytes) in [
                ("PNG", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] as [UInt8]),
                ("JPEG", [0xFF, 0xD8, 0xFF, 0xE0]),
                ("GIF", Array("GIF89a".utf8)),
                ("TIFF LE", [0x49, 0x49, 0x2A, 0x00]),
                ("TIFF BE", [0x4D, 0x4D, 0x00, 0x2A]),
                ("BMP", Array("BM".utf8) + [0x00, 0x00]),
            ] {
                T.expect(ImageCache.isAcceptedPicture(Data(bytes + [UInt8](repeating: 0, count: 16))),
                         "\(what) is accepted")
            }
            // Containers, matched on the brand rather than a fixed prefix.
            let webp = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + [0, 0, 0, 0])
            T.expect(ImageCache.isAcceptedPicture(webp), "WebP is accepted")
            let heic = Data([0, 0, 0, 0] + Array("ftypheic".utf8) + [0, 0, 0, 0])
            T.expect(ImageCache.isAcceptedPicture(heic), "HEIC is accepted")
            let avif = Data([0, 0, 0, 0] + Array("ftypavif".utf8) + [0, 0, 0, 0])
            T.expect(ImageCache.isAcceptedPicture(avif), "AVIF is accepted")

            for (what, bytes) in [
                ("DICOM", [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)),
                ("OpenEXR", [0x76, 0x2F, 0x31, 0x01]),
                ("Radiance", Array("#?RADIANCE".utf8)),
                ("DDS", Array("DDS ".utf8)),
                ("PICT", [UInt8](repeating: 0, count: 522)),
                ("an empty body", []),
            ] {
                T.expect(!ImageCache.isAcceptedPicture(Data(bytes)), "\(what) is refused")
            }

            // **Only a GIF prefix may be drawn.** A picture over
            // `fullFetchCeiling` is read as a head rather than whole, and a
            // GIF stores its frames in order so the first is complete as soon
            // as it arrives. Every other format here holds one picture, so a
            // prefix of it is the top of a photograph over grey — worse than
            // showing nothing. Measured case: an 11,591,322-byte 172-frame GIF
            // on a README, whose first frame decodes identically from the
            // first 128 KB.
            T.expect(ImageCache.isGIF(Data(Array("GIF89a".utf8))), "GIF89a is a GIF")
            T.expect(ImageCache.isGIF(Data(Array("GIF87a".utf8))), "and so is GIF87a")
            for (what, bytes) in [
                ("PNG", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] as [UInt8]),
                ("JPEG", [0xFF, 0xD8, 0xFF, 0xE0]),
                ("TIFF", [0x49, 0x49, 0x2A, 0x00]),
                ("WebP", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)),
                ("a short body", [0x47, 0x49]),
                ("an empty body", []),
            ] {
                T.expect(!ImageCache.isGIF(Data(bytes)), "\(what) is not, so it is never part-drawn")
            }
            T.expect(ImageCache.headFetchBytes < ImageCache.fullFetchCeiling,
                     "the head read is smaller than the ceiling that triggers it")

            // **SVG is how a lot of the web ships a picture**, and the cache
            // took raster formats only. Measured across one real log: 33
            // refusals, the largest group shields.io badges proxied through
            // camo, the next a site whose og:image is an SVG.
            for (what, text) in [
                ("a bare root", "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"),
                // The real og:image case, and the one a first version of this
                // got wrong: the prologue has to be walked past, not just
                // tolerated.
                ("an XML declaration first", "<?xml version=\"1.0\"?><svg width=\"1200\"></svg>"),
                ("leading whitespace", "\n  <svg/>"),
                ("a comment first", "<!-- made by hand --><svg/>"),
                ("a doctype first", "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x.dtd\"><svg/>"),
                ("upper case", "<SVG XMLNS=\"x\"></SVG>"),
            ] {
                T.expect(ImageCache.isSVG(Data(text.utf8)), "SVG: \(what)")
            }
            for (what, text) in [
                // A page with an inline icon is not a picture, and a test that
                // looked for `<svg` anywhere would have called it one.
                ("an HTML page carrying an inline icon",
                 "<!DOCTYPE html><html><body><p>hi</p><svg/></body></html>"),
                ("a feed", "<?xml version=\"1.0\"?><rss><channel><title>x</title></channel></rss>"),
                ("plain text", "not markup at all"),
                ("an unterminated prologue", "<?xml version=\"1.0\""),
                ("nothing", ""),
            ] {
                T.expect(!ImageCache.isSVG(Data(text.utf8)), "not SVG: \(what)")
            }
            T.expect(!ImageCache.isSVG(Data([0x89, 0x50, 0x4E, 0x47])), "not SVG: PNG bytes")

            // The floor that separates a badge from a picture is the one that
            // already separates a favicon from a picture. Nothing new decides
            // it. Measured: shields.io badge 110x20, og:image 1200x630.
            T.expect(20 < ImageCache.minimumPixels,
                     "a badge is below the furniture floor")
            T.expect(630 > ImageCache.minimumPixels,
                     "and an og:image is above it")
            T.expect(ImageCache.maxSVGSource == 64 * 1024,
                     "the source ceiling matches the reader's inline one")
        }

        T.suite("Pictures: a card is decoded for its column, not for the ceiling") {
            let ceiling = ImageCache.maxPixelSize
            func edge(_ want: Int?, _ w: Int, _ h: Int) -> Int {
                ImageCache.decodeLongEdge(drawWidthPx: want, sourceWidth: w, sourceHeight: h)
            }

            // Nil is the reader and the lead: as large as the source or the
            // ceiling allows, which is what every caller used to get.
            T.equal(edge(nil, 6000, 4000), ceiling, "nil takes the ceiling")
            T.equal(edge(nil, 1200, 630), 1200, "or the source, when that is smaller")

            // A landscape card. 400pt column at 2x is 800px, and for a
            // landscape picture the width IS the long edge.
            T.equal(edge(800, 1200, 630), 800, "a landscape card asks for its column")

            // **The case that makes this a width and not a long edge.** A
            // 1000x2000 portrait asked for at an 800px LONG edge comes back
            // 400 wide, and nothing here upscales, so a 400pt column would
            // draw it at 200pt. Converted through the aspect it is 1600, so
            // the picture fills the column.
            T.equal(edge(800, 1000, 2000), 1600, "a portrait card asks for the taller edge")
            T.expect(edge(800, 1000, 2000) > 800, "which is more than the width, not less")

            // Never upscale, and never past the ceiling.
            T.equal(edge(800, 300, 200), 300, "a source smaller than the column is not blown up")
            T.equal(edge(99_999, 6000, 4000), ceiling, "and an absurd request still meets the ceiling")
            T.equal(edge(800, 1000, 30_000), ceiling,
                    "a very tall portrait is held to the ceiling too")

            // Degenerate inputs answer the ceiling rather than trapping.
            T.equal(edge(0, 1200, 630), 1200, "a zero width is treated as unset")
            T.equal(edge(-5, 1200, 630), 1200, "and so is a negative one")
            T.equal(edge(800, 0, 0), ceiling, "a source of unknown size takes the ceiling")

            // **A rotated photograph is sized on the axis it will DRAW at,
            // not the one it is stored on.** `kCGImagePropertyPixelWidth` is
            // the stored width and the decode applies the EXIF rotation, so a
            // 4000x3000 phone photograph with a quarter-turn flag comes back
            // portrait. Found in the log as `image: 4000x3000 -> 473x631`: the
            // card asked for 631px of width and got 473, which nothing
            // upscales, so it would have drawn at 236pt in a 315pt column.
            for upright in [1, 2, 3, 4] {
                let d = ImageCache.drawnSize(width: 4000, height: 3000, orientation: upright)
                T.equal(d.width, 4000, "orientation \(upright) leaves the axes alone")
            }
            for turned in [5, 6, 7, 8] {
                let d = ImageCache.drawnSize(width: 4000, height: 3000, orientation: turned)
                T.equal(d.width, 3000, "orientation \(turned) swaps them")
                T.equal(d.height, 4000, "both ways round")
            }
            // The measured case, end to end. Stored 4000x3000, drawn 3000x4000,
            // a card wanting 631px of width.
            let turned = ImageCache.drawnSize(width: 4000, height: 3000, orientation: 6)
            let asked = edge(631, turned.width, turned.height)
            T.equal(asked, 842, "so the long edge asked for covers the width")
            // Rounding UP is what makes this exact rather than one short.
            T.equal(asked * turned.width / turned.height, 631,
                    "landing the drawn width on the column itself, not three-quarters of it")

            // The saving this was built for, stated as the arithmetic rather
            // than as a claim: a 1200x630 og:image drawn in a 400pt column.
            let full = 1200 * 630 * 4
            let card = edge(800, 1200, 630) * (edge(800, 1200, 630) * 630 / 1200) * 4
            T.expect(card * 2 < full, "a card bitmap is less than half the full-size one")
        }

        T.suite("Live page: a picture with no words is not a drawn page") {
            func drawn(_ text: Int, _ media: Int) -> Bool {
                _ = media
                return LivePagePolicy.hasSomethingToRead(text: text)
            }
            // **Media alone used to be enough.** Measured across 51 real
            // live-page loads: ten produced zero characters of text and the
            // lowest non-zero result was 102, with nothing in between. All ten
            // were paywalls, bot checks or script-built pages — a WSJ
            // paywall, The Economist, two Reddit threads, mastodon.social,
            // AccuWeather with 67 painted media elements, MDPI and the rest.
            T.expect(!drawn(0, 1), "one picture and no words is not drawn")
            T.expect(!drawn(0, 2), "nor is two — the MDPI case")
            T.expect(!drawn(0, 67), "nor sixty-seven — the AccuWeather case")
            T.expect(!drawn(0, 0), "and nothing at all certainly is not")

            // **The reported case, and the reason media was dropped from the
            // rule entirely.** A LessWrong comment permalink drew ONE
            // character of text beside three pictures. The previous rule was
            // `media >= 1 && text > 0`, written on a measured gap — zero, or
            // at least 102, nothing between — and this landed in the gap and
            // showed a blank pane. A gap in 51 samples is not a law.
            T.expect(!drawn(1, 3), "one character beside three pictures is not a page")
            T.expect(!drawn(40, 3), "nor is half a sentence beside them")
            T.expect(!drawn(79, 9), "a picture cannot make up the difference")

            // Text alone, at the floor.
            T.expect(drawn(LivePagePolicy.readableTextFloor, 0),
                     "the text floor itself counts")
            T.expect(!drawn(LivePagePolicy.readableTextFloor - 1, 0),
                     "one short of it, with no picture, does not")
            // The lowest real non-zero measurement, which must still draw.
            T.expect(drawn(102, 0), "the smallest real page measured still draws")
        }

        T.suite("Pictures: the GIF and SVG ceilings hold together") {
            T.expect(ImageCache.minimumPixels > 0, "the furniture floor is real")
        }

        T.suite("Quadratic: an empty body is a dead feed, not a moved one") {
            // A bare `parseFailure` is what `fetchSelfHealing` reads as "try
            // discovery", and an empty 200 was the only way to produce one.
            // That is the unattended route to the scan above.
            let feed = Feed(url: URL(string: "https://example.com/feed.xml")!,
                            section: "News", title: nil)
            for (what, body) in [("zero bytes", ""), ("one space", " "),
                                 ("a bare CRLF", "\r\n"), ("tabs and newlines", "\t\n \r\n")] {
                do {
                    _ = try FeedFetcher.parse(Data(body.utf8), from: feed)
                    T.expect(false, "\(what) should not parse")
                } catch FeedFetchError.parseFailure {
                    T.expect(false, "\(what) still gives the bare failure that triggers discovery")
                } catch {
                    T.expect(true, "\(what) fails with a reason, so discovery is not tried")
                }
            }
        }

        T.suite("Quadratic: a standfirst with no closing bracket is cheap") {
            // 32 KB of bare `<`, which measured 11.0 s, and `<p a` filler,
            // which measured 4.24 s. Both per item, sixteen feeds at a time.
            for (what, filler) in [("bare <", "<"), ("<p a", "<p a")] {
                let body = String(repeating: filler, count: 32 * 1024 / filler.count)
                timed("extracting a standfirst from 32 KB of \(what)") {
                    _ = Standfirst.extract(from: body)
                }
            }
        }
    }
}
