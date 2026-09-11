import Foundation

/// When the reader supplies the paper's own hero, and when it must not.
enum ReaderLedeTests {

    private static let hero = URL(string: "https://cdn.arstechnica.net/wp-content/uploads/2026/09/rocket-1152x648.jpg")!

    private static func decide(_ kinds: [String], _ srcs: [String?] = []) -> URL? {
        let sources = srcs.isEmpty ? Array(repeating: String?.none, count: kinds.count) : srcs
        return ReaderLede.hero(hero, blockKinds: kinds, blockSources: sources)
    }

    static func run() {
        T.suite("Reader lede: supplied when the article opens without one") {
            // The measured majority case: first image a long way down.
            let deep = Array(repeating: "paragraph", count: 22) + ["image"] + Array(repeating: "paragraph", count: 5)
            T.equal(decide(deep), hero, "first image at block 22")
            T.equal(decide(["heading", "paragraph", "paragraph", "paragraph", "image"]), hero,
                    "first image just outside the window")
            T.equal(decide(Array(repeating: "paragraph", count: 30)), hero, "no images at all")
            T.equal(decide([]), hero, "no blocks at all")
        }

        T.suite("Reader lede: withheld when the article already opens with a picture") {
            T.expect(decide(["image", "paragraph"]) == nil, "image first")
            T.expect(decide(["heading", "image", "paragraph"]) == nil, "after a heading")
            T.expect(decide(["heading", "paragraph", "paragraph", "image"]) == nil,
                     "at the last block inside the window")
            // The boundary, stated both ways so a change to ledeWindow shows up
            // here rather than in the reader.
            T.equal(ReaderLede.ledeWindow, 4, "the window is four blocks")
        }

        T.suite("Reader lede: withheld when the same picture appears later") {
            // A CDN appends sizing parameters, and serves the same file over
            // either scheme, so the same photograph must not be shown twice
            // merely because the URLs differ textually.
            let same = "https://cdn.arstechnica.net/wp-content/uploads/2026/09/rocket-1152x648.jpg?w=800"
            let deep = Array(repeating: "paragraph", count: 10) + ["image"]
            let srcs: [String?] = Array(repeating: nil, count: 10) + [same]
            T.expect(decide(deep, srcs) == nil, "same file with a query appended")

            let httpVersion = "http://cdn.arstechnica.net/wp-content/uploads/2026/09/rocket-1152x648.jpg"
            T.expect(decide(deep, Array(repeating: nil, count: 10) + [httpVersion]) == nil,
                     "same file over http")

            let different = "https://cdn.arstechnica.net/wp-content/uploads/2026/09/engines.jpg"
            T.equal(decide(deep, Array(repeating: nil, count: 10) + [different]), hero,
                    "a different picture later does not suppress the lede")
        }

        T.suite("Reader lede: a CDN transform is unwrapped to the file it transforms") {
            // Verbatim shapes from rbaldwin.substack.com, where the reader
            // showed the same chart twice: once as the lede it supplied and
            // once as the article's own copy. Same host, same picture,
            // different transform parameters in the path.
            let file = "https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F6ffa9394-10d4-4114-8337-db903354d268_1379x776.png"
            let heroURL = "https://substackcdn.com/image/fetch/$s_!k441!,w_1200,h_675,c_fill,f_jpg,q_auto:good,fl_progressive:steep,g_auto/" + file
            let inArticle = "https://substackcdn.com/image/fetch/w_1456,c_limit,f_webp,q_auto:good,fl_progressive:steep/" + file
            T.equal(ReaderLede.key(heroURL), ReaderLede.key(inArticle),
                    "two transforms of one file are one picture")

            let hero = URL(string: heroURL)!
            let deep = Array(repeating: "paragraph", count: 6) + ["image"]
            let srcs: [String?] = Array(repeating: nil, count: 6) + [inArticle]
            T.expect(ReaderLede.hero(hero, blockKinds: deep, blockSources: srcs) == nil,
                     "so the lede is withheld")

            // A different file behind the same transform is still different.
            let other = "https://substackcdn.com/image/fetch/w_1456/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F2e0913ca-b957-4dd4-8e56-076ee11f641b_602x338.png"
            T.expect(ReaderLede.key(heroURL) != ReaderLede.key(other),
                     "a different file is not folded together")
            T.equal(ReaderLede.hero(hero, blockKinds: deep,
                                    blockSources: Array(repeating: nil, count: 6) + [other]),
                    hero, "and the lede is still supplied")

            // The same shape from other services.
            T.equal(ReaderLede.key("https://i0.wp.com/example.com/a/pic.jpg?resize=600"),
                    ReaderLede.key("https://example.com/a/pic.jpg"), "WordPress i0.wp.com")
            T.equal(ReaderLede.key("https://res.cloudinary.com/x/image/fetch/w_500/https%3A%2F%2Fexample.com%2Fa%2Fpic.jpg"),
                    ReaderLede.key("https://example.com/a/pic.jpg"), "Cloudinary")

            // An ordinary URL is untouched, including one whose path merely
            // contains the letters "http".
            T.equal(ReaderLede.key("https://example.com/a/pic.jpg"), "example.com/a/pic.jpg", "plain")
            T.equal(ReaderLede.key("https://example.com/httpd/logo.png"),
                    "example.com/httpd/logo.png", "a path containing 'http'")
        }

        T.suite("Reader lede: nothing to supply") {
            T.expect(ReaderLede.hero(nil, blockKinds: ["paragraph"], blockSources: [nil]) == nil,
                     "the paper has no hero for this item")
        }

        T.suite("Reader lede: how two pictures are judged the same") {
            let a = ReaderLede.key("https://cdn.example.com/a/b/pic.jpg?w=800&h=600")
            let b = ReaderLede.key("http://CDN.example.com/a/b/pic.jpg")
            T.equal(a, b, "scheme, case and query are ignored")
            T.expect(a != ReaderLede.key("https://cdn.example.com/a/b/other.jpg"), "the path is not")
            T.expect(ReaderLede.key("not a url at all").isEmpty == false, "a bad url is its own key")
        }
    }
}
