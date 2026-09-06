import AppKit
import Foundation

/// Fits a standfirst to the space it has, in as many columns as its measure
/// warrants.
///
/// Two things this guarantees that `lineLimit` cannot. The text always ends on
/// a finished sentence, because the *content* is cut to fit rather than the
/// rendering being clipped — nothing sets `lineLimit`, so there is no ellipsis
/// to land mid-word. And the line length stays inside the range type is
/// comfortable to read at, by splitting a wide measure into columns.
///
/// Everything here lays text out, so it runs on the main thread only, from
/// views. `Standfirst.extract` is the half that runs on the fetch thread and it
/// deliberately does no layout.
extension Standfirst {

    // MARK: - Type metrics

    /// The font a standfirst is set in, in the form both AppKit (to measure)
    /// and SwiftUI (to draw) need.
    struct Metrics: Hashable {
        let fontName: String
        let size: CGFloat
        let lineSpacing: CGFloat

        static let lead = Metrics(fontName: "Charter", size: 14, lineSpacing: 4)
        static let card = Metrics(fontName: "Charter", size: 12, lineSpacing: 2)

        var nsFont: NSFont { NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size) }
    }

    // MARK: - Knobs

    /// How wide one column of body type wants to be.
    ///
    /// Typography puts comfortable reading between 45 and 75 characters a
    /// line, with about 66 as the ideal. Measured at Charter 14 across the
    /// real standfirsts: 300pt gives a median of 45 characters, 420pt gives
    /// 64, 460pt gives 71 and 490pt gives 75. 440pt lands on the ideal.
    ///
    /// For scale, the lead was running at 113 characters a line at full width.
    /// That is what "the lines are too long" measures out as: half as long
    /// again as type is comfortable at.
    static let idealColumnWidthDefault: CGFloat = 440

    /// The gap between columns, wide enough that the eye does not jump the gap
    /// mid-line but not so wide the deck stops reading as one block.
    static let columnGutterDefault: CGFloat = 32

    /// The fewest lines worth setting as a column of its own.
    ///
    /// Below this a split does more harm than the long measure it was meant to
    /// fix: a two-line standfirst divided in two leaves half a sentence
    /// stranded across the gutter, reading as a fault rather than a deck. Three
    /// is the point at which a column looks deliberate.
    static let minLinesPerColumn = 3

    static let idealColumnWidthKey = "standfirstIdealColumnWidth"

    static var idealColumnWidth: CGFloat {
        let stored = UserDefaults.standard.double(forKey: idealColumnWidthKey)
        return stored > 0 ? CGFloat(stored) : idealColumnWidthDefault
    }

    // MARK: - Planning

    /// A standfirst cut and split for one particular width.
    struct Plan: Equatable {
        /// One string per column, already fitted. Never truncated mid-sentence.
        let columns: [String]
        let gutter: CGFloat
    }

    /// How many columns a standfirst of this width should be set in.
    ///
    /// Rounding to the nearest whole number of ideal-width columns rather than
    /// flooring, because a measure slightly under the ideal reads far better
    /// than one half as long again over it. At the widths the paper can take
    /// (804–1004pt for the lead) this gives 2, putting the measure at 58–75
    /// characters; a card's 252–316pt column gives 1.
    static func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        let ideal = idealColumnWidth
        let gutter = columnGutterDefault
        return max(1, Int(((width + gutter) / (ideal + gutter)).rounded()))
    }

    /// Cuts `text` to fit `maxLines` lines per column at `width`, and splits it
    /// across however many columns that width warrants.
    static func plan(_ text: String, width: CGFloat, metrics: Metrics, maxLines: Int) -> Plan {
        let gutter = columnGutterDefault
        guard width > 0, !text.isEmpty else { return Plan(columns: [text], gutter: gutter) }

        let count = columnCount(for: width)
        let columnWidth = (width - gutter * CGFloat(count - 1)) / CGFloat(count)
        let key = CacheKey(text: text, width: columnWidth.rounded(), metrics: metrics, maxLines: maxLines, columns: count)
        if let hit = cache.value(for: key) { return hit }

        let pieces = units(of: text)

        // Two different cuts, at two different granularities, and they are not
        // the same problem.
        //
        // Where the text ENDS has to be a whole sentence, because the reader
        // has nowhere to continue: a cut there is a truncation.
        let capacity = maxLines * count
        let fitted = join(pieces, upTo: longestPrefix(of: pieces, within: capacity, width: columnWidth, metrics: metrics))
        guard count > 1 else {
            let plan = Plan(columns: [fitted], gutter: gutter)
            cache.store(plan, for: key)
            return plan
        }

        // Where one column HANDS OVER to the next is not a truncation — the
        // sentence carries on at the top of the next column, which is what a
        // newspaper column does. So columns divide at a line, not a sentence.
        // Dividing at sentences was leaving a 4-line column beside a 7-line
        // one, because a paragraph that will not fit the balanced share has to
        // go over whole.
        let starts = lineStarts(of: fitted, width: columnWidth, metrics: metrics)

        // How many columns the WIDTH allows is not how many the TEXT wants. A
        // two-line standfirst split into two one-line columns reads as a
        // layout error, with half a sentence marooned across a gutter. Columns
        // are only worth having if each carries enough lines to read as one, so
        // a short standfirst takes a single column and leaves the rest of the
        // measure as white space — which is what a newspaper does with a short
        // deck. The column keeps its planned width either way, so the line
        // length stays comfortable.
        //
        // The line INDEX only estimates that, because a column that inherits a
        // paragraph break loses the blank line to trimming and draws shorter
        // than its share. So the estimate is a starting point and the DRAWN
        // result is what decides: drop a column and re-split until every column
        // that exists earns its place.
        var used = max(1, min(count, starts.count / minLinesPerColumn))
        var drawn = split(fitted, starts: starts, into: used, of: count, width: columnWidth, metrics: metrics)
        while used > 1, drawn.contains(where: { !$0.isEmpty && lineCount($0, width: columnWidth, metrics: metrics) < minLinesPerColumn }) {
            used -= 1
            drawn = split(fitted, starts: starts, into: used, of: count, width: columnWidth, metrics: metrics)
        }

        let plan = Plan(columns: drawn, gutter: gutter)
        cache.store(plan, for: key)
        return plan
    }

    /// Divides `fitted` into `used` columns, padded out to `total` slots, and
    /// nudges the boundaries until the columns draw as evenly as they can.
    private static func split(
        _ fitted: String,
        starts: [String.Index],
        into used: Int,
        of total: Int,
        width: CGFloat,
        metrics: Metrics
    ) -> [String] {
        let perColumn = max(1, Int((Double(starts.count) / Double(used)).rounded(.up)))
        var boundaries = (1..<used).map { $0 * perColumn }

        // An even share of the line INDEX is not an even share of the drawn
        // column. The blank line a paragraph break leaves behind counts as a
        // line here but is trimmed off the column that inherits it, which pulls
        // that column up to two lines short. So nudge each boundary a line or
        // two either way and keep whichever split actually draws most evenly.
        for position in boundaries.indices {
            let lower = position == 0 ? 1 : boundaries[position - 1] + 1
            let upper = position == boundaries.count - 1 ? starts.count - 1 : boundaries[position + 1] - 1
            guard lower <= upper else { continue }
            var best = boundaries
            var bestSpread = spread(of: columns(in: fitted, starts: starts, boundaries: boundaries, padTo: used), width: width, metrics: metrics)
            for candidate in max(lower, boundaries[position] - 2)...min(upper, boundaries[position] + 2) {
                var trial = boundaries
                trial[position] = candidate
                let trialSpread = spread(of: columns(in: fitted, starts: starts, boundaries: trial, padTo: used), width: width, metrics: metrics)
                if trialSpread < bestSpread {
                    bestSpread = trialSpread
                    best = trial
                }
            }
            boundaries = best
        }
        return columns(in: fitted, starts: starts, boundaries: boundaries, padTo: total)
    }

    /// Cuts `text` at the given line boundaries, one string per column.
    ///
    /// A column that picks up after a paragraph break must not open on the
    /// blank line that break left behind, so each piece is trimmed.
    private static func columns(in text: String, starts: [String.Index], boundaries: [Int], padTo total: Int) -> [String] {
        let edges = [0] + boundaries
        return edges.enumerated().map { position, first in
            guard first < starts.count else { return "" }
            let limit = position + 1 < edges.count ? edges[position + 1] : starts.count
            let upper = limit < starts.count ? starts[limit] : text.endIndex
            return String(text[starts[first]..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        } + Array(repeating: "", count: max(0, total - edges.count))
    }

    /// Difference between the tallest and shortest drawn column. Zero is even.
    private static func spread(of columns: [String], width: CGFloat, metrics: Metrics) -> Int {
        let heights = columns.map { lineCount($0, width: width, metrics: metrics) }
        guard let high = heights.max(), let low = heights.min() else { return 0 }
        return high - low
    }

    // MARK: - Sentence units

    /// A standfirst broken into the smallest pieces we are willing to cut at:
    /// whole sentences, each remembering whether it opened a paragraph.
    private struct Unit {
        let text: String
        let startsParagraph: Bool
    }

    private static func units(of text: String) -> [Unit] {
        var out: [Unit] = []
        for (index, paragraph) in text.components(separatedBy: "\n\n").enumerated() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for (offset, sentence) in sentences(of: trimmed).enumerated() {
                out.append(Unit(text: sentence, startsParagraph: index > 0 && offset == 0))
            }
        }
        return out
    }

    /// Rejoins the first `count` units, restoring the paragraph breaks. A chunk
    /// that begins mid-paragraph does not open with a blank line.
    private static func join(_ pieces: [Unit], upTo count: Int) -> String {
        var out = ""
        for unit in pieces.prefix(count) {
            if out.isEmpty { out = unit.text }
            else if unit.startsParagraph { out += "\n\n" + unit.text }
            else { out += " " + unit.text }
        }
        return out
    }

    /// The most whole sentences that lay out within `maxLines`.
    ///
    /// Binary search, so a 30-sentence standfirst costs 5 layout passes rather
    /// than 30. Always returns at least one sentence: a single sentence too
    /// long for its box is better shown overflowing than replaced by nothing.
    private static func longestPrefix(of pieces: [Unit], within maxLines: Int, width: CGFloat, metrics: Metrics) -> Int {
        guard !pieces.isEmpty else { return 0 }
        if lineCount(join(pieces, upTo: pieces.count), width: width, metrics: metrics) <= maxLines {
            return pieces.count
        }
        var low = 1
        var high = pieces.count
        while low < high {
            let mid = (low + high + 1) / 2
            if lineCount(join(pieces, upTo: mid), width: width, metrics: metrics) <= maxLines {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    // MARK: - Measurement

    /// Lays `text` out and hands the layout manager to `body`.
    ///
    /// A closure rather than a returned manager, because a layout manager does
    /// not keep its text storage alive. Handing back both and trusting the
    /// caller to hold the storage is a trap — dropping it gives a manager that
    /// reports zero glyphs rather than an error, so every measurement silently
    /// comes back as "no lines". Scoping it here means it cannot be dropped.
    private static func withLayout<T>(
        _ text: String,
        width: CGFloat,
        metrics: Metrics,
        _ body: (NSLayoutManager) -> T
    ) -> T {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = metrics.lineSpacing
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: text,
            attributes: [.font: metrics.nsFont, .paragraphStyle: style]
        ))
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return withExtendedLifetime(storage) { body(manager) }
    }

    /// Where each rendered line begins. Column boundaries are taken from this
    /// so a column starts exactly where a line would have broken anyway, which
    /// is what lets a column be re-wrapped on its own and come out the same.
    static func lineStarts(of text: String, width: CGFloat, metrics: Metrics) -> [String.Index] {
        guard !text.isEmpty, width > 0 else { return [] }
        return withLayout(text, width: width, metrics: metrics) { manager in
            var starts: [String.Index] = []
            var glyph = 0
            while glyph < manager.numberOfGlyphs {
                var effective = NSRange()
                manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
                let characters = manager.characterRange(forGlyphRange: effective, actualGlyphRange: nil)
                if let range = Range(characters, in: text) { starts.append(range.lowerBound) }
                glyph = NSMaxRange(effective)
            }
            return starts
        }
    }

    /// How many lines `text` takes at `width`. TextKit rather than a character
    /// estimate, because the whole point is to know before drawing.
    static func lineCount(_ text: String, width: CGFloat, metrics: Metrics) -> Int {
        guard !text.isEmpty, width > 0 else { return 0 }
        return withLayout(text, width: width, metrics: metrics) { manager in
            var lines = 0
            var index = 0
            while index < manager.numberOfGlyphs {
                var effective = NSRange()
                manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
                index = NSMaxRange(effective)
                lines += 1
            }
            return lines
        }
    }

    /// What a planned standfirst will actually stand to, for the masonry's
    /// first-pass seed. The tallest column decides, since they sit side by side.
    static func height(of plan: Plan, width: CGFloat, metrics: Metrics) -> CGFloat {
        let count = max(1, plan.columns.count)
        let columnWidth = (width - plan.gutter * CGFloat(count - 1)) / CGFloat(count)
        let lines = plan.columns.map { lineCount($0, width: columnWidth, metrics: metrics) }.max() ?? 0
        guard lines > 0 else { return 0 }
        let lineHeight = metrics.nsFont.ascender - metrics.nsFont.descender + metrics.nsFont.leading
        return CGFloat(lines) * (lineHeight + metrics.lineSpacing) - metrics.lineSpacing
    }

    // MARK: - Cache

    /// Planning costs a handful of TextKit passes, and a view's body runs far
    /// more often than the inputs change. Keyed on everything that can alter
    /// the answer, with the width rounded so a drag-resize does not miss on
    /// every fractional point.
    private struct CacheKey: Hashable {
        let text: String
        let width: CGFloat
        let metrics: Metrics
        let maxLines: Int
        let columns: Int
    }

    private final class PlanCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CacheKey: Plan] = [:]

        func value(for key: CacheKey) -> Plan? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ plan: Plan, for key: CacheKey) {
            lock.lock(); defer { lock.unlock() }
            // A resize walks through many widths and an edition turns over
            // daily, so the map is dropped wholesale rather than grown without
            // limit. Replanning is a few microseconds; leaking is forever.
            if entries.count > 4000 { entries.removeAll(keepingCapacity: true) }
            entries[key] = plan
        }
    }

    private static let cache = PlanCache()
}
