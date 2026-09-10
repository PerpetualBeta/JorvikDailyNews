import Foundation

/// Following a frame is a guess, and the cost of guessing wrong is showing
/// somebody's advertising in place of an honest "no article here". These cases
/// are mostly about what must NOT be followed.
enum EmbeddedArticleTests {

    private static let base = URL(string: "https://example.com/page")!

    static func run() {
        T.suite("Frames: the Hugging Face Space case") {
            // 28,153 characters of site chrome holding 50 characters of
            // article, with the real piece in a frame.
            let html = #"<div><iframe src="https://huggingenvs-geoguesser-article.hf.space/" "#
                     + #"allowfullscreen></iframe></div>"#
            T.equal(EmbeddedArticle.candidate(in: html, base: base)?.absoluteString,
                    "https://huggingenvs-geoguesser-article.hf.space/", "follows the frame")
        }

        T.suite("Frames: resolved against the page") {
            T.equal(EmbeddedArticle.candidate(in: #"<iframe src="/embed/story">"#, base: base)?
                        .absoluteString,
                    "https://example.com/embed/story", "a relative src resolves")
            T.equal(EmbeddedArticle.candidate(in: #"<iframe src='//cdn.example/x'>"#, base: base)?
                        .absoluteString,
                    "https://cdn.example/x", "single quotes and protocol-relative")
        }

        T.suite("Frames: players and embeds are never the article") {
            for src in ["https://www.youtube.com/embed/abc",
                        "https://player.vimeo.com/video/1",
                        "https://open.spotify.com/embed/track/x",
                        "https://platform.twitter.com/embed/x.html",
                        "https://disqus.com/embed/comments/",
                        "https://www.googletagmanager.com/ns.html?id=GTM-1",
                        "https://www.facebook.com/plugins/like.php"] {
                T.expect(EmbeddedArticle.candidate(in: "<iframe src=\"\(src)\">", base: base) == nil,
                         "refuses \(URL(string: src)!.host ?? src)")
            }
        }

        T.suite("Frames: tracking pixels wearing an iframe") {
            T.expect(EmbeddedArticle.candidate(
                in: #"<iframe src="https://tracker.example/p" width="1" height="1">"#,
                base: base) == nil, "1x1 is not an article")
            T.expect(EmbeddedArticle.candidate(
                in: #"<iframe src="https://tracker.example/p" width="0" height="0">"#,
                base: base) == nil, "nor is 0x0")
            // A frame that sizes itself in CSS declares nothing, and most
            // full-bleed embeds are exactly that, so no size is not a reason
            // to refuse.
            T.expect(EmbeddedArticle.candidate(
                in: #"<iframe src="https://writing.example/piece">"#,
                base: base) != nil, "no declared size is not suspicious")
        }

        T.suite("Frames: nothing to follow") {
            T.expect(EmbeddedArticle.candidate(in: "<p>An ordinary page.</p>", base: base) == nil,
                     "no frame at all")
            T.expect(EmbeddedArticle.candidate(in: #"<iframe src="">"#, base: base) == nil,
                     "an empty src")
            T.expect(EmbeddedArticle.candidate(in: "<iframe>", base: base) == nil,
                     "no src attribute")
            T.expect(EmbeddedArticle.candidate(in: #"<iframe src="about:blank">"#, base: base) == nil,
                     "a non-http scheme")
            T.expect(EmbeddedArticle.candidate(in: #"<iframe src="javascript:0">"#, base: base) == nil,
                     "javascript")
        }

        T.suite("Frames: the first usable one wins") {
            // A tracker first, then the real thing.
            let html = #"<iframe src="https://www.googletagmanager.com/ns.html" height="0"></iframe>"#
                     + #"<iframe src="https://writing.example/piece"></iframe>"#
            T.equal(EmbeddedArticle.candidate(in: html, base: base)?.absoluteString,
                    "https://writing.example/piece", "skips the tracker, takes the article")
        }

        T.suite("Frames: case and spacing in the markup") {
            T.equal(EmbeddedArticle.candidate(
                        in: #"<IFRAME  SRC = "https://writing.example/p"  >"#, base: base)?
                        .absoluteString,
                    "https://writing.example/p", "uppercase tag and spaced attribute")
            T.equal(EmbeddedArticle.candidate(
                        in: "<iframe src=\"\n  https://writing.example/p \n\">", base: base)?
                        .absoluteString,
                    "https://writing.example/p", "whitespace inside the value")
        }
    }
}
