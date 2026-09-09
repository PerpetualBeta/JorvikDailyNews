import Foundation

/// One piece of an article, in the only shapes a reader needs to draw.
///
/// Flat and dull on purpose. `ReaderBlocks.js` walks Readability's HTML and
/// emits this, so the renderer never has to understand markup, and anything
/// the walker cannot classify is dropped there rather than guessed at here.
///
/// It exists so an article can be drawn without WebKit. Extraction stopped
/// needing a web view in 1.4.5; the display did not, and on both machines
/// this app has been tested on, `loadHTMLString` intermittently renders
/// nothing at all with no error — so an article that extracted perfectly
/// still showed a blank page. This is the other half of that fix.
struct ReaderBlock: Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case paragraph, heading, image, svg, list, quote, code, rule, table
    }

    /// A stretch of text sharing one set of inline attributes.
    struct Run: Codable, Sendable, Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
        let code: Bool
        let href: String?
    }

    let kind: Kind
    var level: Int?
    var runs: [Run]?
    var src: String?
    var alt: String?
    var caption: [Run]?
    var svg: String?
    var width: Double?
    var height: Double?
    var ordered: Bool?
    var items: [Item]?

    /// One line of a list, with the depth it sits at.
    ///
    /// A flat `[[Run]]` could not express nesting, and the walker was welding
    /// a nested list's items onto its parent's text: "First itemNested one
    /// Nested two", no separator and no bullets. Each item now carries its own
    /// depth, ordered-ness and position, so the renderer indents and numbers
    /// without knowing anything about HTML.
    struct Item: Codable, Sendable {
        let runs: [Run]
        var depth: Int = 0
        var ordered: Bool = false
        var index: Int = 1
    }
    var text: String?
    var rows: [[[Run]]]?

    /// Stable within one article, which is all `ForEach` needs. Deliberately
    /// not derived from the content: two identical paragraphs in one article
    /// are not unusual, and a content hash would collide and silently drop
    /// one — a fault this project has already met in the masonry.
    var id: Int { position }
    var position: Int = 0

    private enum CodingKeys: String, CodingKey {
        case kind, level, runs, src, alt, caption, svg, width, height
        case ordered, items, text, rows
    }
}

extension ReaderBlock.Run {
    /// The plain text, for measuring and for accessibility.
    var plain: String { text }
}

extension Array where Element == ReaderBlock {
    /// Number each block once, after decoding, so `id` is stable and unique.
    func numbered() -> [ReaderBlock] {
        enumerated().map { index, block in
            var copy = block
            copy.position = index
            return copy
        }
    }

    var plainText: String {
        compactMap { block -> String? in
            if let runs = block.runs { return runs.map(\.text).joined() }
            if let text = block.text { return text }
            if let items = block.items { return items.map { $0.runs.map(\.text).joined() }.joined(separator: "\n") }
            return nil
        }.joined(separator: "\n\n")
    }
}
