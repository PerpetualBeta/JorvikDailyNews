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
