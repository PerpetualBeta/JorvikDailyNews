import Foundation

/// The Swift half of the block ceilings.
///
/// `ReaderBlocks.js` applies them while walking, and this restates them at
/// decode time. Two halves, because the walker is JavaScript in a bundled
/// resource: if only one half enforced a rule, one edit to the other would
/// remove it silently. `InlineSVG.maxSource` is there for the same reason.
enum ReaderBlockTests {

    private static func decode(_ json: String) -> [ReaderBlock] {
        (try? JSONDecoder().decode([ReaderBlock].self, from: Data(json.utf8))) ?? []
    }

    private static func run(_ block: ReaderBlock) -> String {
        (block.runs ?? []).map(\.text).joined()
    }

    static func run() {
        let cap = [ReaderBlock].maxBlockChars

        T.suite("Blocks: one block's text has a ceiling") {
            let long = String(repeating: "x", count: cap + 500)
            let blocks = decode("""
            [{"kind":"paragraph","runs":[{"text":"\(long)","bold":false,"italic":false,"code":false}]}]
            """).numbered()
            T.equal(blocks.count, 1, "the block survives")
            T.equal(run(blocks[0]).count, cap, "its text is cut to the ceiling")
        }

        T.suite("Blocks: the budget is shared across runs") {
            // Ten runs of a tenth of the ceiling each fit; eleven do not. A
            // per-run ceiling would let any number of runs through, which is
            // the shape a hostile page would use.
            let piece = String(repeating: "y", count: cap / 10)
            func paragraph(of count: Int) -> String {
                let runs = (0..<count).map {
                    _ in "{\"text\":\"\(piece)\",\"bold\":false,\"italic\":false,\"code\":false}"
                }.joined(separator: ",")
                return "[{\"kind\":\"paragraph\",\"runs\":[\(runs)]}]"
            }
            T.equal(run(decode(paragraph(of: 10)).numbered()[0]).count, (cap / 10) * 10,
                    "ten runs of a tenth each all survive")
            T.equal(run(decode(paragraph(of: 40)).numbered()[0]).count, cap, "forty do not exceed it")
        }

        T.suite("Blocks: code text is cut, and lists are bounded twice") {
            let long = String(repeating: "z", count: cap * 2)
            let code = decode("[{\"kind\":\"code\",\"text\":\"\(long)\"}]").numbered()
            T.equal(code[0].text?.count, cap, "a <pre> body is cut")

            let item = "{\"runs\":[{\"text\":\"q\",\"bold\":false,\"italic\":false,\"code\":false}],"
                     + "\"depth\":0,\"ordered\":false,\"index\":1}"
            let items = (0..<3000).map { _ in item }.joined(separator: ",")
            let list = decode("[{\"kind\":\"list\",\"items\":[\(items)]}]").numbered()
            T.equal(list[0].items?.count, [ReaderBlock].maxBlockParts,
                    "and a list keeps at most maxBlockParts items")
        }

        T.suite("Blocks: an absurd source is dropped, not drawn") {
            let src = "data:image/png;base64," + String(repeating: "A", count: 128 * 1024)
            let blocks = decode("[{\"kind\":\"image\",\"src\":\"\(src)\"}]").numbered()
            T.expect(blocks[0].src == nil, "a src past the ceiling is removed")

            let ok = decode("[{\"kind\":\"image\",\"src\":\"https://e.com/a.png\"}]").numbered()
            T.equal(ok[0].src, "https://e.com/a.png", "an ordinary one is kept whole")
        }

        T.suite("Blocks: an ordinary article is untouched") {
            let blocks = decode("""
            [{"kind":"paragraph","runs":[{"text":"Some ordinary prose.","bold":false,"italic":false,"code":false}]},
             {"kind":"heading","level":2,"runs":[{"text":"A heading","bold":false,"italic":false,"code":false}]}]
            """).numbered()
            T.equal(run(blocks[0]), "Some ordinary prose.", "prose passes through")
            T.equal(run(blocks[1]), "A heading", "and so does a heading")
            T.equal(blocks[1].position, 1, "positions still number from zero")
        }
    }
}
