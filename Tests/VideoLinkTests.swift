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
