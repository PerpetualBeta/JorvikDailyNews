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

    /// Turns character references back into the characters they stand for.
    ///
    /// Scans ONCE, left to right, and never looks at what it has written. A
    /// sequence of `replacingOccurrences` calls cannot do this: replacing
    /// `&amp;` first turns a literal `&amp;lt;` into `&lt;`, and the later pass
    /// then turns that into `<`, so text the source deliberately escaped comes
    /// out as markup.
    ///
    /// Numeric references are decoded arithmetically rather than listed.
    /// Measured across 39 subscribed feeds, numeric forms are where the old
    /// fixed list failed and failed widely: `&#039;` appears 3,073 times,
    /// `&#8217;` 1,720, `&#39;` 1,164, `&#92;` 410 and `&#xA0;` 397, against a
    /// table that held only `&#39;` and `&#8217;`. A leading zero alone was
    /// enough to defeat it. Two rules now cover the whole space.
    ///
    /// Named references are a small closed set in practice — 16 distinct across
    /// those feeds — but the tail is accented letters, so the table below is
    /// generated from the HTML5 named-character-reference set rather than typed
    /// out, restricted to the ranges that turn up in prose: Latin-1, General
    /// Punctuation, and the arrows and maths signs feeds use.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var index = s.startIndex
        while let ampersand = s[index...].firstIndex(of: "&") {
            out += s[index..<ampersand]
            let body = s[s.index(after: ampersand)...].prefix(maxReferenceLength)
            if let terminator = body.firstIndex(of: ";"),
               let scalar = scalar(forReference: body[..<terminator]) {
                out.unicodeScalars.append(scalar)
                index = s.index(after: terminator)
            } else {
                // Not a reference: a bare ampersand in running text. Keep it and
                // carry on past it, so the scan cannot stall.
                out.append("&")
                index = s.index(after: ampersand)
            }
        }
        out += s[index...]
        return out
    }

    /// The longest reference worth looking for. Long enough for the longest
    /// name in the table and any numeric form, short enough that a bare
    /// ampersand in prose does not drag the scan across a whole paragraph.
    private static let maxReferenceLength = 32

    private static func scalar(forReference body: Substring) -> Unicode.Scalar? {
        guard !body.isEmpty else { return nil }
        let value: UInt32?
        if body.first == "#" {
            let digits = body.dropFirst()
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
        } else {
            value = namedReferences[String(body)]
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        // A reference that decodes to a control character is a broken feed, not
        // a character anyone meant. Leave the source text alone rather than
        // planting an invisible control code in a headline.
        if value < 0x20, value != 0x09, value != 0x0A, value != 0x0D { return nil }
        return scalar
    }

    /// Generated from Python's `html.entities.html5`, so the spellings and code
    /// points are the standard's rather than remembered.
    private static let namedReferences: [String: UInt32] = [
        "AElig": 0x00c6, "Aacute": 0x00c1, "Acirc": 0x00c2, "Agrave": 0x00c0,
        "Aring": 0x00c5, "Atilde": 0x00c3, "Auml": 0x00c4, "COPY": 0x00a9,
        "Ccedil": 0x00c7, "Cedilla": 0x00b8, "CenterDot": 0x00b7, "CloseCurlyDoubleQuote": 0x201d,
        "CloseCurlyQuote": 0x2019, "Dagger": 0x2021, "DiacriticalAcute": 0x00b4, "Dot": 0x00a8,
        "DoubleDot": 0x00a8, "DownArrow": 0x2193, "ETH": 0x00d0, "Eacute": 0x00c9,
        "Ecirc": 0x00ca, "Egrave": 0x00c8, "Euml": 0x00cb, "GreaterEqual": 0x2265,
        "Iacute": 0x00cd, "Icirc": 0x00ce, "Igrave": 0x00cc, "Iuml": 0x00cf,
        "LeftArrow": 0x2190, "LeftRightArrow": 0x2194, "NonBreakingSpace": 0x00a0, "NotEqual": 0x2260,
        "Ntilde": 0x00d1, "OElig": 0x0152, "Oacute": 0x00d3, "Ocirc": 0x00d4,
        "Ograve": 0x00d2, "OpenCurlyDoubleQuote": 0x201c, "OpenCurlyQuote": 0x2018, "Oslash": 0x00d8,
        "Otilde": 0x00d5, "Ouml": 0x00d6, "PlusMinus": 0x00b1, "Prime": 0x2033,
        "REG": 0x00ae, "RightArrow": 0x2192, "Scaron": 0x0160, "ShortDownArrow": 0x2193,
        "ShortLeftArrow": 0x2190, "ShortRightArrow": 0x2192, "ShortUpArrow": 0x2191, "THORN": 0x00de,
        "TRADE": 0x2122, "TildeTilde": 0x2248, "Uacute": 0x00da, "Ucirc": 0x00db,
        "Ugrave": 0x00d9, "UpArrow": 0x2191, "Uuml": 0x00dc, "Verbar": 0x2016,
        "Vert": 0x2016, "Yacute": 0x00dd, "Yuml": 0x0178, "aacute": 0x00e1,
        "acirc": 0x00e2, "acute": 0x00b4, "aelig": 0x00e6, "agrave": 0x00e0,
        "amp": 0x0026, "angst": 0x00c5, "ap": 0x2248, "apos": 0x0027,
        "approx": 0x2248, "aring": 0x00e5, "asymp": 0x2248, "atilde": 0x00e3,
        "auml": 0x00e4, "backprime": 0x2035, "bdquo": 0x201e, "bprime": 0x2035,
        "brvbar": 0x00a6, "bull": 0x2022, "bullet": 0x2022, "ccedil": 0x00e7,
        "cedil": 0x00b8, "cent": 0x00a2, "centerdot": 0x00b7, "circledR": 0x00ae,
        "copy": 0x00a9, "curren": 0x00a4, "dagger": 0x2020, "darr": 0x2193,
        "dash": 0x2010, "ddagger": 0x2021, "deg": 0x00b0, "die": 0x00a8,
        "div": 0x00f7, "divide": 0x00f7, "downarrow": 0x2193, "eacute": 0x00e9,
        "ecirc": 0x00ea, "egrave": 0x00e8, "eth": 0x00f0, "euml": 0x00eb,
        "euro": 0x20ac, "fnof": 0x0192, "frac12": 0x00bd, "frac14": 0x00bc,
        "frac34": 0x00be, "ge": 0x2265, "geq": 0x2265, "gt": 0x003e,
        "half": 0x00bd, "harr": 0x2194, "hellip": 0x2026, "horbar": 0x2015,
        "hyphen": 0x2010, "iacute": 0x00ed, "icirc": 0x00ee, "iexcl": 0x00a1,
        "igrave": 0x00ec, "infin": 0x221e, "iquest": 0x00bf, "iuml": 0x00ef,
        "laquo": 0x00ab, "larr": 0x2190, "ldquo": 0x201c, "ldquor": 0x201e,
        "le": 0x2264, "leftarrow": 0x2190, "leftrightarrow": 0x2194, "leq": 0x2264,
        "lsaquo": 0x2039, "lsquo": 0x2018, "lsquor": 0x201a, "lt": 0x003c,
        "macr": 0x00af, "mdash": 0x2014, "micro": 0x00b5, "middot": 0x00b7,
        "minus": 0x2212, "mldr": 0x2026, "nbsp": 0x00a0, "ndash": 0x2013,
        "ne": 0x2260, "nldr": 0x2025, "not": 0x00ac, "ntilde": 0x00f1,
        "oacute": 0x00f3, "ocirc": 0x00f4, "oelig": 0x0153, "ograve": 0x00f2,
        "ordf": 0x00aa, "ordm": 0x00ba, "oslash": 0x00f8, "otilde": 0x00f5,
        "ouml": 0x00f6, "para": 0x00b6, "permil": 0x2030, "pertenk": 0x2031,
        "plusmn": 0x00b1, "pm": 0x00b1, "pound": 0x00a3, "prime": 0x2032,
        "quot": 0x0022, "raquo": 0x00bb, "rarr": 0x2192, "rdquo": 0x201d,
        "rdquor": 0x201d, "reg": 0x00ae, "rightarrow": 0x2192, "rsaquo": 0x203a,
        "rsquo": 0x2019, "rsquor": 0x2019, "sbquo": 0x201a, "scaron": 0x0161,
        "sect": 0x00a7, "shy": 0x00ad, "slarr": 0x2190, "srarr": 0x2192,
        "strns": 0x00af, "sup1": 0x00b9, "sup2": 0x00b2, "sup3": 0x00b3,
        "szlig": 0x00df, "thickapprox": 0x2248, "thkap": 0x2248, "thorn": 0x00fe,
        "times": 0x00d7, "tprime": 0x2034, "trade": 0x2122, "uacute": 0x00fa,
        "uarr": 0x2191, "ucirc": 0x00fb, "ugrave": 0x00f9, "uml": 0x00a8,
        "uparrow": 0x2191, "uuml": 0x00fc, "yacute": 0x00fd, "yen": 0x00a5,
        "yuml": 0x00ff
    ]

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
