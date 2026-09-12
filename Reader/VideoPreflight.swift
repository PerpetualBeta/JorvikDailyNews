import Foundation

/// Looks at what a "video" link actually serves, before `AVPlayer` is given it.
///
/// **The problem this exists for.** `AVPlayer` decides what to do from the
/// bytes, not the path, and it will follow an HLS playlist to whatever URLs the
/// playlist names. Measured on 2026-09-11 against a local server: a URL ending
/// `.mp4` that served `#EXTM3U` made the player fetch a segment URL the app had
/// never seen, and a real `.m3u8` did the same, which is how the test was known
/// to be detecting following rather than missing it.
///
/// So a check applied only to the link is cosmetic: the link is the one URL an
/// attacker does not need. Reading the first bytes is what turns "the path says
/// `.mp4`" into "the response is a video file".
///
/// **Refusing HLS outright is a deliberate trade.** It costs live streams,
/// which a feed item linking a bare `.mp4` almost never is.
///
/// **What it does NOT do, corrected after the second review.** An earlier
/// version of this comment claimed it "buys the only reliable way to stop one
/// checked URL becoming a list of unchecked ones". That was wrong. This check
/// and `AVPlayer` make **two independent requests**: this one through
/// `URLSession` with a `Range` header, the player's through AVFoundation with
/// its own user agent moments later. A server can tell them apart trivially and
/// answer them differently — a real MP4 prefix here, `#EXTM3U` to the player.
///
/// So this raises the bar; it does not close the hole. Closing it needs an
/// `AVAssetResourceLoaderDelegate` serving every byte the player asks for, via
/// a custom scheme, so the policy sees each request. That is a much larger
/// piece of work and has not been done. What genuinely limits the exposure is
/// that nothing is fetched at all until the reader presses play.
enum VideoPreflight {

    /// How much of the body to look at. An HLS playlist announces itself in the
    /// first seven bytes; this is generous so a server that pads or sends a BOM
    /// is still read correctly, and small enough to cost nothing.
    static let inspectBytes = 64 * 1024

    enum Verdict: Equatable {
        case play
        case refuse(String)
    }

    /// The decision, from the bytes and the declared type alone.
    ///
    /// Foundation only and no networking, so the suite can exercise every case
    /// without a server.
    static func verdict(bytes: Data, contentType: String?) -> Verdict {
        let declared = (contentType ?? "").lowercased()

        // A playlist by declaration. Both spellings are in use: the registered
        // type and the older Apple one.
        if declared.contains("mpegurl") || declared.contains("m3u8") {
            return .refuse("it is a streaming playlist, not a video file")
        }
        // DASH, for the same reason — a manifest naming other URLs.
        if declared.contains("dash+xml") {
            return .refuse("it is a streaming manifest, not a video file")
        }
        // A web page. Usually a link that needed the article extractor, not a
        // sign of anything hostile, but it is certainly not a video.
        if declared.contains("text/html") || declared.contains("application/xhtml") {
            return .refuse("the server sent a web page, not a video")
        }

        // A playlist by content, whatever the server called it. This is the
        // check that matters: the declared type is the attacker's to choose.
        //
        // **Done on bytes, not on a decoded String.** Two faults lived here.
        // The window was `prefix(64)` — 64 bytes, while `inspectBytes` says
        // 64 KB and the fetch honours it — so a playlist with a little padding
        // was never examined. And the test sat inside
        // `if let text = String(data:encoding:.utf8)`, whose initialiser is
        // strict: a multi-byte character straddling the last byte of the slice
        // returns nil and execution fell through to `.play`. The file could be
        // a perfectly valid playlist; only the slice was invalid.
        //
        // A byte scan has neither problem. `#EXTM3U` is seven ASCII bytes and
        // ASCII cannot straddle anything.
        if startsWithPlaylistMarker(bytes) {
            return .refuse("it is a streaming playlist, not a video file")
        }

        // Anything else is handed to AVFoundation, which is the only thing that
        // can really say whether it is playable. Nothing here tries to validate
        // a container format: guessing at one would give false confidence
        // without removing the parse.
        return .play
    }

    /// Whether the body's first non-blank bytes are `#EXTM3U`.
    ///
    /// Leading whitespace and a UTF-8 or UTF-16 byte-order mark are skipped —
    /// all of them are ways of pushing the marker out of a naive window — and
    /// the skip is bounded so a body that is nothing but whitespace cannot make
    /// this loop the length of the response.
    /// **Every reading of the bytes, and a playlist if ANY of them is one.**
    ///
    /// De-interleaving used to be inferred from a single NUL at offset 0 or 1
    /// and applied destructively, so one NUL inserted into a plain ASCII
    /// playlist made the scan drop every other byte and the marker vanish. The
    /// comment above calls this "the check that matters", so it had to stop
    /// being decided by one byte.
    ///
    /// The three readings are cheap and independent: as delivered, and
    /// de-interleaved from either offset. A file is refused if the marker is
    /// found in any of them.
    /// Its own session, for a wall-clock ceiling.
    ///
    /// **`timeoutInterval` is an idle timeout**, so a server dribbling one
    /// byte every few seconds resets it for ever — `BoundedFetch`'s own header
    /// says so, and this sink does not go through `BoundedFetch`. It is on
    /// `URLSession.shared` no longer, because a resource ceiling belongs to
    /// this read and not to every request the app makes. 64 KB has no business
    /// taking half a minute.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func startsWithPlaylistMarker(_ bytes: Data) -> Bool {
        let boms: [[UInt8]] = [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF]]
        var b = [UInt8](bytes.prefix(inspectBytes))
        for bom in boms where b.starts(with: bom) {
            b.removeFirst(bom.count)
            break
        }
        if markerLeads(b) { return true }
        // UTF-16 spells the marker with a NUL after each byte, in either
        // order. Tried as alternatives, not as a replacement.
        guard b.count >= 2 else { return false }
        if markerLeads(stride(from: 0, to: b.count, by: 2).map { b[$0] }) { return true }
        return markerLeads(stride(from: 1, to: b.count, by: 2).map { b[$0] })
    }

    private static func markerLeads(_ b: [UInt8]) -> Bool {
        let marker = Array("#EXTM3U".utf8)
        var i = 0
        let skipLimit = min(b.count, 4096)
        while i < skipLimit,
              b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x00 {
            i += 1
        }
        guard b.count - i >= marker.count else { return false }
        return Array(b[i..<(i + marker.count)]).elementsEqual(marker)
    }

    /// Reads a bounded prefix of the response and returns the verdict.
    ///
    /// Deliberately not `BoundedFetch`: that refuses a body whose *declared*
    /// length is over its ceiling, and a hostile server could declare a huge
    /// length to skip the inspection entirely. This reads at most
    /// `inspectBytes` and then stops, whatever the server claimed.
    static func check(_ url: URL, timeout: TimeInterval = 12) async -> Verdict {
        // The same scheme and private-host rule the rest of the app uses. The
        // player never asked this question, so a feed could aim it at the
        // local network; verified by playing from 127.0.0.1 with no complaint.
        guard WebURL.isAllowed(url) else {
            jdnLog("video: refused \(url.scheme ?? "(no scheme)") — not a public web address")
            return .refuse("that is not a public web address")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Ask for a prefix. A server may ignore it, which is why the read below
        // stops on its own count rather than trusting the response.
        request.setValue("bytes=0-\(inspectBytes - 1)", forHTTPHeaderField: "Range")

        do {
            // This sink does not go through BoundedFetch, so it installs the
            // redirect guard itself.
            let (stream, response) = try await Self.session.bytes(
                for: request, delegate: RedirectGuard())
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                jdnLog("video: \(url.host ?? "?") returned HTTP \(http.statusCode)")
                return .refuse("the server returned HTTP \(http.statusCode)")
            }
            var head = Data()
            for try await byte in stream {
                head.append(byte)
                if head.count >= inspectBytes { break }
            }
            let type = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
            let verdict = verdict(bytes: head, contentType: type)
            jdnLog("video: \(head.count) bytes inspected, type \(type ?? "none") — "
                   + (verdict == .play ? "playing" : "refused"))
            return verdict
        } catch {
            jdnLog("video: could not inspect \(url.host ?? "?") — \(error.localizedDescription)")
            return .refuse(error.localizedDescription)
        }
    }
}
