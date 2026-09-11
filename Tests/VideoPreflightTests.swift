import Foundation

/// The decision that stops one checked URL becoming a list of unchecked ones.
///
/// Every refusal case here was reproduced against a local server first: a URL
/// ending `.mp4` serving `#EXTM3U` made `AVPlayer` fetch a segment URL the app
/// had never seen.
enum VideoPreflightTests {

    private static func bytes(_ s: String) -> Data { Data(s.utf8) }
    private static let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4.0,\nhttp://evil/seg.ts\n"
    /// An MP4 begins with a box length then `ftyp`.
    private static let mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)

    static func run() {
        T.suite("Video preflight: a playlist is refused however it is dressed") {
            // By content, whatever the server calls it — this is the one that
            // matters, because the declared type is the attacker's to choose.
            for declared in ["video/mp4", "application/octet-stream", "text/plain", ""] {
                let v = VideoPreflight.verdict(bytes: bytes(playlist),
                                               contentType: declared.isEmpty ? nil : declared)
                T.expect(v != .play, "content #EXTM3U refused when declared \(declared.isEmpty ? "(nothing)" : declared)")
            }
            T.expect(VideoPreflight.verdict(bytes: bytes(playlist), contentType: nil) != .play,
                     "and with no Content-Type at all")
            // Leading whitespace or a BOM must not be a way past it.
            T.expect(VideoPreflight.verdict(bytes: bytes("\n\n  " + playlist), contentType: "video/mp4") != .play,
                     "leading whitespace")
            T.expect(VideoPreflight.verdict(bytes: bytes("\u{FEFF}" + playlist), contentType: "video/mp4") != .play,
                     "a byte-order mark")
            // By declaration, both spellings in use.
            for declared in ["application/vnd.apple.mpegurl", "application/x-mpegURL",
                             "audio/mpegurl", "application/dash+xml"] {
                T.expect(VideoPreflight.verdict(bytes: mp4, contentType: declared) != .play,
                         "declared \(declared)")
            }
        }

        T.suite("Video preflight: a web page is refused") {
            T.expect(VideoPreflight.verdict(bytes: bytes("<!DOCTYPE html>"),
                                            contentType: "text/html; charset=utf-8") != .play,
                     "a .mp4 path that serves HTML")
            T.expect(VideoPreflight.verdict(bytes: bytes("<html>"),
                                            contentType: "application/xhtml+xml") != .play, "xhtml")
        }

        T.suite("Video preflight: a real video plays") {
            T.equal(VideoPreflight.verdict(bytes: mp4, contentType: "video/mp4"), .play, "an mp4")
            T.equal(VideoPreflight.verdict(bytes: mp4, contentType: "video/quicktime"), .play, "a mov")
            T.equal(VideoPreflight.verdict(bytes: mp4, contentType: "application/octet-stream"), .play,
                    "an unhelpful type over real video bytes")
            T.equal(VideoPreflight.verdict(bytes: mp4, contentType: nil), .play, "no type at all")
            T.equal(VideoPreflight.verdict(bytes: Data(), contentType: "video/mp4"), .play,
                    "an empty prefix is left to AVFoundation rather than guessed at")
            // "#EXTM3U" must be at the START. A video whose bytes happen to
            // contain it later is not a playlist.
            T.equal(VideoPreflight.verdict(bytes: mp4 + bytes(playlist), contentType: "video/mp4"), .play,
                    "the marker later in the file is not the marker")
        }

        T.suite("Video preflight: the ways past the old window") {
            // The window was prefix(64) while inspectBytes said 64 KB, and the
            // test sat inside a STRICT String(data:encoding:.utf8) that
            // returned nil on a multi-byte character straddling the slice —
            // falling through to .play on a perfectly valid playlist.
            let pad = String(repeating: " ", count: 200)
            T.expect(VideoPreflight.verdict(bytes: bytes(pad + playlist), contentType: "video/mp4") != .play,
                     "200 bytes of leading whitespace")
            T.expect(VideoPreflight.verdict(bytes: bytes("\n\n\t  \r\n" + playlist), contentType: "video/mp4") != .play,
                     "mixed whitespace")
            // A multi-byte character straddling byte 63 of the old slice.
            let straddle = String(repeating: "a", count: 62) + "\u{00E9}"
            T.expect(VideoPreflight.verdict(bytes: bytes(straddle) + bytes(playlist),
                                            contentType: "video/mp4") == .play,
                     "junk then a playlist is not a playlist — the marker must be FIRST")
            let straddleThenMarker = bytes(String(repeating: " ", count: 62) + "\u{00E9}")
            T.expect(VideoPreflight.verdict(bytes: straddleThenMarker + bytes(playlist),
                                            contentType: "video/mp4") == .play,
                     "and a non-space character still means it does not start with one")
            // UTF-16, both ends.
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf16] {
                let data = playlist.data(using: encoding) ?? Data()
                T.expect(VideoPreflight.verdict(bytes: data, contentType: "video/mp4") != .play,
                         "a UTF-16 playlist in \(encoding)")
            }
            // A UTF-8 BOM in front of it.
            T.expect(VideoPreflight.verdict(bytes: Data([0xEF, 0xBB, 0xBF]) + bytes(playlist),
                                            contentType: "video/mp4") != .play, "a UTF-8 BOM")
            // Nothing but whitespace must not spin.
            T.equal(VideoPreflight.verdict(bytes: bytes(String(repeating: " ", count: 70_000)),
                                           contentType: "video/mp4"), .play, "whitespace only")
        }

        T.suite("Video preflight: the inspection window") {
            T.equal(VideoPreflight.inspectBytes, 64 * 1024, "64 KB, enough for any playlist")
        }
    }
}
