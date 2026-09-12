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
