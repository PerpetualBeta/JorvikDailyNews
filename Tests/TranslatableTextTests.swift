import Foundation

/// Which text the reader translates, and how a translation is put back.
///
/// Pure, so it is tested here without an engine. The engines themselves are
/// Apple's and are exercised by hand: a test cannot download a language pair.
enum TranslatableTextTests {
    private static func run(_ text: String, href: String? = nil, bold: Bool = false) -> ReaderBlock.Run {
        ReaderBlock.Run(text: text, bold: bold, italic: false, code: false, href: href)
    }

    private static let title = TranslationKey(block: -1, part: .runs)

    private static func article() -> [ReaderBlock] {
        var blocks: [ReaderBlock] = [
            ReaderBlock(kind: .paragraph, runs: [run("La început, "), run("Basgan", href: "https://example.com"), run(" a oferit.")]),
            ReaderBlock(kind: .heading, level: 2, runs: [run("Brevetul")]),
            ReaderBlock(kind: .code, text: "let x = 1"),
            ReaderBlock(kind: .rule),
            ReaderBlock(kind: .list, ordered: true, items: [
                ReaderBlock.Item(runs: [run("Forajul sonic")], depth: 0, ordered: true, index: 1),
                ReaderBlock.Item(runs: [run("Rezonanța")], depth: 1, ordered: true, index: 2),
            ]),
            ReaderBlock(kind: .image, src: "https://example.com/a.jpg", caption: [run("Sonda")]),
            ReaderBlock(kind: .paragraph, runs: [run("1.")]),
        ]
        for i in blocks.indices { blocks[i].position = i }
        return blocks
    }

    static func run() {
        T.suite("Translation: the prose is picked, in reading order, the headline first") {
            let pieces = TranslatableText.pieces(title: "Inovația", blocks: article(), titleKey: title)
            T.equal(pieces.first?.key, title, "the headline comes first")
            T.equal(pieces.map(\.text), ["Inovația", "La început, Basgan a oferit.", "Brevetul",
                                         "Forajul sonic", "Rezonanța", "Sonda"],
                    "a paragraph is one piece however many runs it has; code, rules and bare numbers are left out")
            T.equal(pieces[3].key, TranslationKey(block: 4, part: .item(0)), "each list line is its own piece")
            T.equal(pieces[5].key, TranslationKey(block: 5, part: .caption), "a caption is translated")
        }

        T.suite("Translation: an article's language is read from its prose, not its opening line") {
            // The real headline and caption from ServeTheHome's article (2026-10-09), which are
            // mostly model numbers, followed by English paragraphs written for this test. On macOS
            // 27.0.1 the old way, one recogniser call on the pieces joined, called this Indonesian:
            // the recogniser judges from the opening and the opening is the headline.
            let english = [
                "Gigabyte W775-V10-L01 Hands-on Bringing NVIDIA GB300 Deskside",
                "GIGABYTE W775-V10-L01-Front Angled 3",
                "This workstation puts a data-centre class accelerator under a desk. It needs a single wall socket, a quiet room and a good deal of patience while it starts, but once it is running it behaves much like any other tower computer, only far faster at the work it was built for.",
                "The case is plain and large. There are no lights on the front, the handles are solid metal, and the side panel comes away without tools, which makes the inside easy to reach when a drive or a memory module has to be changed.",
                "External Hardware Overview",
                "On the back there are several network ports, a few USB connectors and a single video output. Most people will reach it over the network rather than plug in a screen, and the vendor clearly expects exactly that.",
            ]
            T.equal(TranslatableText.language(of: english), .english,
                    "English prose under a headline of model numbers is English")

            // The other way round: the same kind of headline over Romanian prose must still be
            // Romanian, or the weighting would just be a bias towards English.
            let romanian = [
                "Gigabyte W775-V10-L01 GB300",
                "La început, inginerii au construit o stație de lucru foarte puternică pentru birou. Ea are nevoie de o singură priză, de o cameră liniștită și de multă răbdare la pornire, dar apoi funcționează ca orice alt calculator.",
                "Carcasa este simplă și mare. Nu există lumini în față, mânerele sunt din metal, iar panoul lateral se scoate fără unelte, ceea ce face interiorul ușor de atins.",
            ]
            T.equal(TranslatableText.language(of: romanian), .romanian,
                    "Romanian prose under a headline of model numbers is still Romanian")

            T.equal(TranslatableText.language(of: []), nil, "no pieces, no language")
        }

        T.suite("Translation: a translated block is drawn as its translation") {
            let original = article()
            let translated = TranslatableText.apply([
                TranslationKey(block: 0, part: .runs): "At first, Basgan offered.",
                TranslationKey(block: 4, part: .item(1)): "Resonance",
                TranslationKey(block: 5, part: .caption): "The well",
            ], to: original)
            T.equal(translated[0].runs?.map(\.text), ["At first, Basgan offered."], "one plain run in place of three")
            T.expect(translated[0].runs?.first?.href == nil, "its link goes with the original until Show Original")
            T.equal(translated[1].runs?.map(\.text), ["Brevetul"], "an untranslated block is left as it was")
            T.equal(translated[4].items?.map { $0.runs.map(\.text).joined() }, ["Forajul sonic", "Resonance"],
                    "only the translated list line changes")
            T.equal(translated[4].items?[1].depth, 1, "and it keeps its depth")
            T.equal(translated[4].items?[1].index, 2, "and its number")
            T.equal(translated[5].caption?.map(\.text), ["The well"], "the caption is replaced")
            T.equal(translated.count, original.count, "no block is added or lost")
        }
    }
}
