import CoreGraphics
import Foundation

/// What a picture looks like, in 116 bytes, so two files can be compared
/// without either being on screen.
///
/// The paper needs this because the same photograph reaches it as several
/// different files. On 9 September 2026 Apple held a launch event and Hacker
/// News submitted every product page separately, including regional variants:
/// `apple.com/iphone-18-pro/` and `apple.com/hk/en/iphone-18-pro/` are two
/// stories with two links and two guids, and dedupe is right to keep both. The
/// same hero shot appeared three times on one page because the three files are
/// genuinely different bytes at different sizes.
///
/// Two halves, because neither alone is enough.
///
/// `edges` is a difference hash: the picture drawn into a 9x8 greyscale grid,
/// recording for each cell whether it is brighter than the cell to its right.
/// 64 comparisons, 64 bits. It survives rescaling and re-encoding, which is
/// exactly what happens between a newsroom tile and a product-page `og:image`.
///
/// `colour` is the mean colour of each cell of a 6x6 grid. It is here because
/// the edge hash alone is not safe on this material, and that was measured,
/// not assumed: Apple's product shots are all a small dark object centred on a
/// white field, so their greyscale gradients agree even when the objects do
/// not. The Apple logo tile and an AirPods tile score 7 bits apart — closer
/// than two genuine copies of the iPhone Duo photograph, which score 8. Adding
/// colour separates them, because the objects differ in hue where the
/// backgrounds do not.
struct PictureSignature: Codable, Equatable {

    /// 9x8 luminance comparisons, one bit each.
    let edges: UInt64
    /// 6x6 cells, three bytes per cell, row-major.
    let colour: [UInt8]

    static let edgeSide = 8
    static let colourSide = 6

    // MARK: - Thresholds

    /// Measured over 47 hero images taken from the paper of 9 September 2026,
    /// against a ground truth read off a contact sheet by eye.
    ///
    /// `edge <= 11 && colour <= 11` catches **7 of the 8** same-picture pairs
    /// with **no false positives**. The one it misses is a re-crop of an Apple
    /// Watch render, at colour 13.
    ///
    /// Loosening colour to 13 catches that eighth pair and admits one wrong
    /// match, and that trade is the wrong way round. A repeat left on the page
    /// is untidy and the reader can see why. A picture suppressed that was
    /// never a repeat silently robs a story of its hero for no reason anybody
    /// could work out, and nothing in the paper would show it had happened.
    /// Where the two errors are not equal, tune to the cheaper one.
    ///
    /// Both conditions must hold. Either alone admits false matches — the
    /// nearest wrong pair scores 7 on edges (well inside this cut) and 41 on
    /// colour (well outside it).
    ///
    /// A finer grid is worse, not better. A 12x12 edge hash separates the same
    /// material less well at every threshold tried, because more cells means
    /// more cells of empty background agreeing with each other.
    static let maxEdgeDistance = 11
    static let maxColourDistance = 11

    // MARK: - Building

    /// Both halves from ONE draw into a 9x8 bitmap, so this costs one small
    /// resample of an image that has already been decoded for display.
    static func of(_ cg: CGImage) -> PictureSignature? {
        let w = edgeSide + 1, h = edgeSide
        let px = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        px.initialize(repeating: 255, count: w * h * 4)
        defer { px.deallocate() }
        guard let ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        // On white, so a transparent PNG compares as it is drawn rather than
        // as whatever happens to be in the buffer.
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        func luminance(_ x: Int, _ y: Int) -> Int {
            let o = (y * w + x) * 4
            return (Int(px[o]) * 299 + Int(px[o + 1]) * 587 + Int(px[o + 2]) * 114) / 1000
        }
        var edges: UInt64 = 0
        var bit = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                if luminance(x, y) > luminance(x + 1, y) { edges |= (1 << UInt64(bit)) }
                bit += 1
            }
        }

        var colour: [UInt8] = []
        colour.reserveCapacity(colourSide * colourSide * 3)
        for gy in 0..<colourSide {
            for gx in 0..<colourSide {
                let x0 = gx * edgeSide / colourSide
                let x1 = max(x0 + 1, (gx + 1) * edgeSide / colourSide)
                let y0 = gy * h / colourSide
                let y1 = max(y0 + 1, (gy + 1) * h / colourSide)
                var r = 0, g = 0, b = 0, n = 0
                for y in y0..<min(h, y1) {
                    for x in x0..<min(edgeSide, x1) {
                        let o = (y * w + x) * 4
                        r += Int(px[o]); g += Int(px[o + 1]); b += Int(px[o + 2]); n += 1
                    }
                }
                if n == 0 { n = 1 }
                colour.append(UInt8(r / n)); colour.append(UInt8(g / n)); colour.append(UInt8(b / n))
            }
        }
        return PictureSignature(edges: edges, colour: colour)
    }

    // MARK: - Comparing

    /// Differing bits between the two edge hashes, 0 to 64.
    func edgeDistance(to other: PictureSignature) -> Int {
        (edges ^ other.edges).nonzeroBitCount
    }

    /// Mean absolute difference per colour channel, 0 to 255.
    func colourDistance(to other: PictureSignature) -> Int {
        guard !colour.isEmpty, colour.count == other.colour.count else { return 255 }
        var total = 0
        for i in 0..<colour.count { total += abs(Int(colour[i]) - Int(other.colour[i])) }
        return total / colour.count
    }

    /// Whether these are the same photograph, at whatever size and encoding.
    func isSamePicture(as other: PictureSignature) -> Bool {
        edgeDistance(to: other) <= Self.maxEdgeDistance
            && colourDistance(to: other) <= Self.maxColourDistance
    }
}
