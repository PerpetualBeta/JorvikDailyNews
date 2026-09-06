import Foundation

/// Turns a feed item's body HTML into a standfirst: the opening paragraphs of
/// the article, with the paragraph breaks still in them.
///
/// The previous `FeedFetcher.htmlToPlain` replaced every tag with a space and
/// then collapsed every run of whitespace. `</p><p>` is the only record of a
/// paragraph break the source gives us, and both halves of that pass destroyed
/// it, so every summary arrived as one unbroken run of the whole article body.
/// A card could truncate that but never break it up, which is why the lead read
/// as a wall of text.
///
/// The filter here is structural, not lexical. There is no list of phrases to
/// recognise — a leading image credit, a `iPad | Mac | iPhone` link row and a
/// social strip have nothing in common textually, but they are all far shorter
/// than a paragraph of prose. Word count alone separates them.
enum Standfirst {

    // MARK: - Knobs

    /// A block shorter than this is not a paragraph of prose.
    ///
    /// Measured over 5,368 blocks taken from 39 of the subscribed feeds: real
    /// opening paragraphs run 20 words and up, while the leading noise (image
    /// credits, bare URLs, `SUPPORT`, `iPad | Mac | iPhone`) is 14 words or
    /// fewer. Every value from 8 to 20 produced an identical result on that
    /// sample, so the exact number is not load-bearing; 15 sits in the middle
    /// of the flat part of the curve. Only at 25 did real paragraphs start
    /// being cut (3 more feeds fell back).
    ///
    /// Link density was measured too, as a second signal, and dropped: once
    /// blocks are filtered by length it changed the outcome for 1 feed of 39,
    /// and changed it for the worse by skipping a genuine paragraph that
    /// happened to carry two links. One knob does the job.
    static let minParagraphWordsDefault = 15

    /// How many words of standfirst to keep for an item.
    ///
    /// This is a storage bound, not a layout one. What actually reaches the
    /// page is decided by `Standfirst.plan`, which measures the text against
    /// the space it has; this only decides how much material that fitting gets
    /// to choose from. Every item is stored at the lead's appetite, because
    /// any item can be promoted to lead when the paper reflows and the body
    /// HTML is not kept in the edition to re-extract from.
    ///
    /// Calibrated by re-extracting the real feeds at each candidate target and
    /// measuring the result against the lead deck's capacity (2 columns of 8
    /// lines at 486pt). The share of leads filling 14 of those 16 lines runs
    /// 67% at 150 words, 72% at 180 and 75% at 210, then stops: past that the
    /// feeds genuinely have no more to give, and the remaining quarter are
    /// simply short articles that no target can fill. 200 sits just under the
    /// plateau.
    ///
    /// Overshooting costs only disk, since the fitter cuts what will not fit.
    static let leadTargetWordsDefault = 200


    static let minWordsKey = "summaryMinParagraphWords"
    static let leadTargetKey = "summaryLeadTargetWords"

    /// Both knobs are live via `defaults write
    /// cc.jorviksoftware.JorvikDailyNews summaryLeadTargetWords -int 260`, so
    /// they are tuned against a real paper rather than guessed at. 0 or absent
    /// means the default.
    static var minParagraphWords: Int { knob(minWordsKey, minParagraphWordsDefault) }
    static var leadTargetWords: Int { knob(leadTargetKey, leadTargetWordsDefault) }

    private static func knob(_ key: String, _ fallback: Int) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : fallback
    }

    // MARK: - Extraction

    /// The opening paragraphs of `html`, separated by a blank line, run out to
    /// the lead's appetite.
    ///
    /// Every item is stored at that length rather than at a card's, because
    /// any item can be promoted to the lead on a reflow and the body HTML is
    /// not kept in the edition to re-extract from. `trim(_:toWords:)` cuts it
    /// back wherever it appears somewhere narrower.
    static func extract(from html: String) -> String {
        let stripped = removeNonProse(html)
        let marked = replace(Patterns.blockEnd, in: stripped, with: separator)
        let minWords = minParagraphWords

        let paragraphs = marked
            .components(separatedBy: separator)
            .map(flatten)
            .filter { wordCount($0) >= minWords }

        let standfirst = accumulate(paragraphs, target: leadTargetWords)
        if !standfirst.isEmpty { return standfirst }

        // Nothing in the body looked like a paragraph. Some items genuinely are
        // one short line ("New release: v2.1 out now."), and showing that beats
        // showing nothing. A body that is only a tracking pixel has no text at
        // all, so it still yields "" and the card closes up.
        return flatten(stripped)
    }


    /// Takes leading paragraphs up to `target` words, separated by a blank
    /// line. A paragraph that fits is taken whole; only the one that crosses
    /// the target gets opened up and taken a sentence at a time, so the
    /// sentence segmenter runs at most once per call.
    ///
    /// Cutting the crossing paragraph matters because some feeds ship an
    /// entire article as a single `<p>` — The Awl's arrives as one 717-word
    /// paragraph — and taking that whole would put the wall back on the page.
    private static func accumulate(_ paragraphs: [String], target: Int) -> String {
        var kept: [String] = []
        var total = 0
        for paragraph in paragraphs {
            if total >= target { break }
            let count = wordCount(paragraph)
            if total + count <= target {
                kept.append(paragraph)
                total += count
                continue
            }
            var partial = ""
            for sentence in sentences(of: paragraph) {
                partial += partial.isEmpty ? sentence : " " + sentence
                total += wordCount(sentence)
                if total >= target { break }
            }
            kept.append(partial.isEmpty ? paragraph : partial)
            break
        }
        return kept.joined(separator: "\n\n")
    }

    /// Drops HTML comments, and the elements whose *contents* are not prose.
    ///
    /// `code` is deliberately absent from that list. It is an inline element
    /// sitting inside sentences, and removing its text leaves holes: "the
    /// property the browser supports is , , or the IE proprietary". `pre` is
    /// the block form and takes the whole listing with it, which is what we
    /// want — a code listing is not a standfirst.
    private static func removeNonProse(_ html: String) -> String {
        let noComments = replace(Patterns.comment, in: html, with: " ")
        return replace(Patterns.nonProse, in: noComments, with: " ")
    }

    /// One block of markup reduced to a single line of readable text.
    private static func flatten(_ chunk: String) -> String {
        // Inline tags are removed rather than replaced with a space, because
        // in HTML they introduce no whitespace. Substituting a space is what
        // used to put the gap in "the famous Doppler effect ." Block
        // boundaries have already become paragraph separators by this point,
        // so nothing that needed to keep words apart is left here.
        var s = replace(Patterns.tag, in: chunk, with: "")
        // Entities are decoded after the tags are gone, never before: decoding
        // first would turn a literal `&lt;script&gt;` into real markup.
        s = decodeEntities(s)
        s = replace(Patterns.whitespace, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).count
    }

    /// Sentence boundaries via Foundation's own text segmentation rather than
    /// a regex on full stops. It already knows that "Dr.", "e.g." and "U.S."
    /// do not end a sentence, which a hand-rolled split would get wrong on the
    /// first article that used one. Returns a single element when the text has
    /// no sentence punctuation at all.
    static func sentences(of s: String) -> [String] {
        var out: [String] = []
        s.enumerateSubstrings(in: s.startIndex..., options: [.bySentences, .localized]) { substring, _, _, _ in
            if let t = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                out.append(t)
            }
        }
        return out.isEmpty ? [s] : out
    }

    // MARK: - Entities

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let pairs: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&ndash;", "\u{2013}"), ("&mdash;", "\u{2014}"),
            ("&hellip;", "\u{2026}"), ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&#8217;", "\u{2019}")
        ]
        for (from, to) in pairs { out = out.replacingOccurrences(of: from, with: to) }
        return out
    }

    // MARK: - Patterns

    /// U+2029 PARAGRAPH SEPARATOR. It means exactly what we are marking, and it
    /// does not occur in feed bodies in practice. Blocks are split on it before
    /// any whitespace pass runs, which matters because ICU's `\s` matches it.
    private static let separator = "\u{2029}"

    private enum Patterns {
        static let comment = regex("<!--.*?-->", dotMatchesLineSeparators: true)
        static let nonProse = regex(
            "<(script|style|pre|figcaption|table|form|noscript|iframe|svg)\\b[^>]*>.*?</\\1\\s*>",
            dotMatchesLineSeparators: true
        )
        static let blockEnd = regex(
            "</(?:p|div|h[1-6]|li|blockquote|section|article|figure|tr|dd|dt)\\s*>|<br\\s*/?>"
        )
        static let tag = regex("<[^>]+>")
        static let whitespace = regex("\\s+")

        private static func regex(_ pattern: String, dotMatchesLineSeparators: Bool = false) -> NSRegularExpression {
            var options: NSRegularExpression.Options = [.caseInsensitive]
            if dotMatchesLineSeparators { options.insert(.dotMatchesLineSeparators) }
            // The patterns are literals in this file. A failure here is a typo,
            // not something a feed can cause, so it should never ship.
            return try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: template
        )
    }
}
