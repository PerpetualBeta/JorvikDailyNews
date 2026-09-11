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
/// which a feed item linking a bare `.mp4` almost never is, and it buys the
/// only reliable way to stop one checked URL becoming a list of unchecked ones
/// short of proxying every request the player makes.
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
        let head = bytes.prefix(64)
        if let text = String(data: head, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                              .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            if trimmed.hasPrefix("#EXTM3U") {
                return .refuse("it is a streaming playlist, not a video file")
            }
        }

        // Anything else is handed to AVFoundation, which is the only thing that
        // can really say whether it is playable. Nothing here tries to validate
        // a container format: guessing at one would give false confidence
        // without removing the parse.
        return .play
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
            let (stream, response) = try await URLSession.shared.bytes(
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
