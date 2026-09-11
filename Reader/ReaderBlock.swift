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

        /// Where a run leads, and by which route.
        ///
        /// Two cases rather than one URL, because they are handled quite
        /// differently: a web address goes to the browser, and an email
        /// address goes to a sheet that shows the reader what is in the link
        /// before Mail is involved at all.
        enum Target: Equatable {
            case web(URL)
            case email(MailtoLink)
        }

        /// What this run links to, if anything.
        func target(relativeTo base: URL) -> Target? {
            if let web = destination(relativeTo: base) { return .web(web) }
            guard let href else { return nil }
            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                  let mail = MailtoLink(url)
            else { return nil }
            return .email(mail)
        }

        /// Where this run leads, or nil if it leads nowhere.
        ///
        /// Resolved against the article's own address, because feeds hand us
        /// plenty of `/news/story` and `../images/x`. A bare fragment resolves
        /// to the article's page with the fragment on it: there are no anchors
        /// in the rendered blocks to jump to, so sending the reader to that
        /// spot on the real page is the honest answer rather than doing
        /// nothing.
        ///
        /// Here rather than in the view so it can be tested. A run that
        /// returns nil is drawn as ordinary text — never underlined, because
        /// something that looks like a link and does nothing is the exact bug
        /// this was written to fix.
        func destination(relativeTo base: URL) -> URL? {
            // http(s) only. This used to reject `javascript:` and pass
            // everything else, which meant an article could hand
            // `NSWorkspace.open` any scheme an installed app had registered:
            // `webcal:` to subscribe Calendar to the attacker's feed for good,
            // `smb:` to prompt Finder for credentials against their host,
            // `ssh:`/`x-man-page:` to put a command line in front of a
            // terminal, `file:///System/Applications/…` to launch an app. One
            // click, no consent step, and drawn identically to a real link.
            WebURL.resolve(href, against: base)
        }
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
    /// The same ceilings the walker applies, restated because the walker is
    /// JavaScript in a bundled resource and this is Swift. A rule enforced in
    /// only one half is one edit away from being gone — the same two-halves
    /// reason `InlineSVG.maxSource` restates the SVG ceiling.
    static var maxBlocks: Int { 4000 }

    /// UTF-16 code units one block may carry, summed over every run, cell or
    /// item.
    ///
    /// **Counted in the unit the walker counts and the layout engine lays
    /// out.** This used to be `String.count`, which is grapheme clusters, so
    /// the two halves were not restatements of one rule — they were two
    /// different rules that agreed only on ASCII. 65,000 clusters of `a` plus
    /// 200 combining accents is 65,000 `Character`s and 13,065,000 UTF-16
    /// units: it passed a ceiling written as 65,536 and reached
    /// `NSLayoutManager`, measured at about 3 s on the main thread.
    static var maxBlockChars: Int { 64 * 1024 }

    /// List items, or table cells, one block may hold.
    static var maxBlockParts: Int { 2000 }

    /// Longest image `src` that will be drawn.
    static var maxSrcChars: Int { 128 * 1024 }

    func numbered() -> [ReaderBlock] {
        if count > Self.maxBlocks {
            jdnLog("reader: \(count) blocks is over the \(Self.maxBlocks) allowed — truncated")
        }
        var cut = 0
        let out = prefix(Self.maxBlocks).enumerated().map { index, block -> ReaderBlock in
            var copy = block.clamped(didCut: &cut)
            copy.position = index
            return copy
        }
        if cut > 0 {
            jdnLog("reader: \(cut) block(s) held more than the \(Self.maxBlockChars) "
                   + "characters or \(Self.maxBlockParts) parts allowed — truncated")
        }
        return out
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

extension ReaderBlock {
    /// Cut this block back to what the renderer can draw without stalling.
    ///
    /// `maxBlocks` bounds how many blocks there are and says nothing about
    /// what is inside one. A single `<pre>`, or a single `<p><a>`, holding
    /// megabytes on one line is one block, and any run carrying a link is
    /// drawn by `ProseText`, whose `sizeThatFits` calls
    /// `NSLayoutManager.ensureLayout` synchronously on the main thread:
    /// about 0.27 s per MB at a 700 pt container, re-run on every size
    /// proposal, so continuously while the window is resized.
    ///
    /// `didCut` counts blocks that lost something, for one log line.
    func clamped(didCut cut: inout Int) -> ReaderBlock {
        var copy = self
        var lost = false

        if let runs {
            var left = [ReaderBlock].maxBlockChars
            let kept = Self.clamp(runs, &left)
            if kept.count != runs.count || left == 0 { lost = true }
            copy.runs = kept
        }
        if let caption {
            var left = [ReaderBlock].maxBlockChars
            copy.caption = Self.clamp(caption, &left)
        }
        if let text, text.storedLength > [ReaderBlock].maxBlockChars {
            copy.text = text.clamped(toUTF16: [ReaderBlock].maxBlockChars)
            lost = true
        }
        if let items {
            var left = [ReaderBlock].maxBlockChars
            var kept: [Item] = []
            for item in items.prefix([ReaderBlock].maxBlockParts) {
                if left <= 0 { break }
                kept.append(Item(runs: Self.clamp(item.runs, &left),
                                 depth: item.depth, ordered: item.ordered, index: item.index))
            }
            if kept.count != items.count { lost = true }
            copy.items = kept
        }
        if let rows {
            var left = [ReaderBlock].maxBlockChars
            var parts = 0
            var keptRows: [[[Run]]] = []
            for row in rows {
                if left <= 0 || parts >= [ReaderBlock].maxBlockParts { break }
                var keptCells: [[Run]] = []
                for cell in row {
                    if parts >= [ReaderBlock].maxBlockParts { break }
                    keptCells.append(Self.clamp(cell, &left))
                    parts += 1
                }
                keptRows.append(keptCells)
            }
            if keptRows.count != rows.count { lost = true }
            copy.rows = keptRows
        }
        // A src this long is not a picture anyone meant to publish, and it is
        // what `ReaderLede.key` would percent-decode on every body pass.
        if let src, src.storedLength > [ReaderBlock].maxSrcChars {
            copy.src = nil
            lost = true
        }

        if lost { cut += 1 }
        return copy
    }

    /// Take runs until the shared character budget runs out, splitting the
    /// run that crosses it.
    private static func clamp(_ runs: [Run], _ left: inout Int) -> [Run] {
        var out: [Run] = []
        out.reserveCapacity(runs.count)
        for run in runs {
            if left <= 0 { break }
            let length = run.text.storedLength
            if length > left {
                out.append(Run(text: run.text.clamped(toUTF16: left), bold: run.bold,
                               italic: run.italic, code: run.code, href: run.href))
                left = 0
                break
            }
            left -= length
            out.append(run)
        }
        return out
    }
}
