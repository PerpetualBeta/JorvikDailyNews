import Foundation

/// Written when video detection moved off `ReaderView`, to prove a verbatim
/// move stayed verbatim. A verbatim move is exactly the kind of change that
/// gets one line wrong and nobody notices for months.
enum VideoLinkTests {
    static func run() {
        T.suite("VideoLink: YouTube") {
            expect("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youTube(dQw4w9WgXcQ)")
            expect("https://youtu.be/dQw4w9WgXcQ",                "youTube(dQw4w9WgXcQ)")
            expect("https://m.youtu.be/dQw4w9WgXcQ",              "youTube(dQw4w9WgXcQ)")
            expect("https://www.youtube.com/shorts/XgJjdkYOKz8",  "youTube(XgJjdkYOKz8)")
            expect("https://www.youtube.com/embed/XgJjdkYOKz8",   "youTube(XgJjdkYOKz8)")
            expect("https://www.youtube.com/v/XgJjdkYOKz8",       "youTube(XgJjdkYOKz8)")
            // A `v` parameter alongside others, which is the usual shape of a
            // link shared from the site itself.
            expect("https://m.youtube.com/watch?v=abc123&t=42",   "youTube(abc123)")
        }

        T.suite("VideoLink: Vimeo") {
            expect("https://vimeo.com/123456789",              "vimeo(123456789)")
            expect("https://player.vimeo.com/video/123456789", "vimeo(123456789)")
        }

        T.suite("VideoLink: direct media") {
            expect("https://example.com/clip.mp4",  "native")
            // Extension matching is case-insensitive; a .MOV from a phone is
            // the common case.
            expect("https://example.com/clip.MOV",  "native")
            expect("https://example.com/clip.webm", "native")
        }

        T.suite("VideoLink: not a video") {
            // A bare host with no id must not classify, or every YouTube link
            // in a feed becomes a player with nothing to play.
            expect("https://www.youtube.com/",                "nil")
            expect("https://vimeo.com/channels/staffpicks",   "nil")
            expect("https://arstechnica.com/some-article",    "nil")
            expect("https://example.com/page.html",           "nil")
        }
    }

    private static func expect(_ raw: String, _ want: String,
                               file: String = #fileID, line: Int = #line) {
        T.equal(describe(VideoLink.detect(URL(string: raw)!)), want, raw, file: file, line: line)
    }

    private static func describe(_ v: VideoLink?) -> String {
        switch v {
        case .youTube(let id): "youTube(\(id))"
        case .vimeo(let id):   "vimeo(\(id))"
        case .native:          "native"
        case nil:              "nil"
        }
    }
}

/// A video id is interpolated into an HTML attribute in a JavaScript-enabled
/// web view, so it has to be validated before it gets there. `pathComponents`
/// and `queryItems` both hand back percent-DECODED text, which is what made
/// this reachable.
enum VideoIDTests {

    static func run() {
        T.suite("Video id: injection payloads are refused") {
            // Proved against the shipping extractor before the guard existed:
            // this produced the id `a"><img src=x onerror=alert(1)>` and put it
            // inside src="https://www.youtube.com/embed/…".
            for raw in ["https://www.youtube.com/watch?v=a%22%3E%3Cimg%20src=x%20onerror=alert(1)%3E",
                        "https://youtu.be/a%22%3E%3Cscript%3Ealert(1)%3C/script%3E",
                        "https://www.youtube.com/embed/a%22%20onload=%22alert(1)",
                        "https://www.youtube.com/watch?v=%3E%3Cimg/src/onerror=alert(1)%3E",
                        "https://vimeo.com/1%22%3E%3Cimg%20src=x%3E",
                        "https://player.vimeo.com/video/%22%3E%3Cscript%3E"] {
                T.expect(VideoLink.detect(URL(string: raw)!) == nil,
                         "refuses \(raw.suffix(38))")
            }
        }

        T.suite("Video id: real ids still play") {
            // The guard must not cost a working video.
            T.expect(VideoLink.detect(URL(string: "https://youtu.be/dQw4w9WgXcQ")!) != nil,
                     "a standard 11-character id")
            T.expect(VideoLink.detect(URL(string: "https://www.youtube.com/shorts/XgJjdkYOKz8")!) != nil,
                     "a shorts id")
            T.expect(VideoLink.detect(URL(string: "https://www.youtube.com/watch?v=abc-DEF_123")!) != nil,
                     "hyphen and underscore are legitimate")
            T.expect(VideoLink.detect(URL(string: "https://vimeo.com/123456789")!) != nil,
                     "a numeric Vimeo id")
        }

        T.suite("Video id: bounded") {
            let long = String(repeating: "a", count: 200)
            T.expect(VideoLink.detect(URL(string: "https://youtu.be/\(long)")!) == nil,
                     "a 200-character id is not an id")
        }
    }
}
