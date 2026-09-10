import Foundation

/// Standfirst is where a fault is visible on the front page and invisible in a
/// log: a welded sentence or a swallowed entity looks like the feed's own bad
/// writing. Every case here is a shape taken from a real subscribed feed.
enum StandfirstTests {

    static func run() {
        T.suite("Entities: one pass, left to right") {
            // The whole reason this is a scanner and not a chain of
            // `replacingOccurrences`. Replacing `&amp;` first turns a literal
            // `&amp;lt;` into `&lt;`, and a later pass then turns that into
            // `<`, so text the author deliberately escaped comes out as
            // markup.
            equal("&amp;lt;script&amp;gt;", "&lt;script&gt;", "an escaped entity stays escaped")
            equal("Marks &amp; Spencer", "Marks & Spencer", "named reference")
            equal("caf&eacute;", "café", "accented letter")
            equal("&ldquo;quoted&rdquo;", "\u{201c}quoted\u{201d}", "curly quotes")
        }

        T.suite("Entities: numeric forms") {
            // A leading zero alone used to defeat the old fixed table, and
            // `&#039;` is the single commonest reference in the subscribed
            // feeds at 3,073 occurrences.
            equal("it&#039;s", "it\u{2019}s".replacingOccurrences(of: "\u{2019}", with: "'"), "decimal with a leading zero")
            equal("it&#39;s", "it's", "decimal without one")
            equal("&#8217;", "\u{2019}", "decimal above the Latin-1 range")
            equal("&#xA0;", "\u{00a0}", "lowercase hex")
            equal("&#XA0;", "\u{00a0}", "uppercase hex")
        }

        T.suite("Entities: what must be left alone") {
            // A bare ampersand in running text is not a reference, and the
            // scan must step past it rather than stall on it.
            equal("Fish & chips & peas", "Fish & chips & peas", "bare ampersands")
            equal("a & b", "a & b", "an ampersand with no semicolon")
            equal("&notareference;", "&notareference;", "an unknown name")
            // A reference decoding to a control character is a broken feed,
            // not a character anyone meant.
            equal("&#1;", "&#1;", "a control character is refused")
            equal("&#9;", "\t", "tab is allowed through")
            // No ampersand at all takes the early return.
            equal("plain text", "plain text", "text with no reference")
        }

        T.suite("Paragraphs: a bare <p> is a boundary") {
            // HTML does not require a closing `</p>`, and Hacker News comments
            // are written exactly that way. The boundary used to match closing
            // tags only, so `flatten` removed the bare `<p>` as an inline tag
            // and the standfirst read "banned it.Some local".
            let welded = Standfirst.extract(from:
                "<p>" + words(20) + " actually banned it."
                + "<p>Some local governments " + words(20) + ".")
            T.expect(!welded.contains("it.Some"), "no welded sentence at a bare <p>")
            T.expect(welded.contains("\n\n"), "the break survives as a paragraph separator")
        }

        T.suite("Paragraphs: inline tags introduce no space") {
            // Substituting a space for an inline tag is what used to put the
            // gap in "the famous Doppler effect ."
            let s = Standfirst.extract(from: "<p>the famous <em>Doppler</em> effect " + words(20) + ".</p>")
            T.expect(!s.contains(" ."), "no space before the full stop")
            T.expect(s.contains("famous Doppler effect"), "words stay joined across an inline tag")
        }

        T.suite("Filter: short blocks are not prose") {
            // A leading image credit, a link row and a social strip have
            // nothing in common textually. Word count alone separates them.
            let s = Standfirst.extract(from:
                "<p>Photo: Getty</p><p>iPad | Mac | iPhone</p><p>SUPPORT</p>"
                + "<p>" + words(30) + "</p>")
            T.expect(!s.contains("Getty"), "an image credit is dropped")
            T.expect(!s.contains("iPad"), "a link row is dropped")
            T.expect(!s.contains("SUPPORT"), "a social strip is dropped")
            T.expect(s.contains("word01"), "the real paragraph survives")
        }

        T.suite("Filter: non-prose elements go whole") {
            let s = Standfirst.extract(from:
                "<script>var x = " + words(30) + ";</script>"
                + "<pre>" + words(30) + "</pre>"
                + "<p>" + words(30) + "</p>")
            T.expect(!s.contains("var x"), "a script's contents are dropped")
            T.expect(s.contains("word01"), "the prose after it survives")
            // `code` is deliberately NOT in that list: it is inline, and
            // removing its text leaves holes in a sentence.
            let inline = Standfirst.extract(from: "<p>the property is <code>flex-basis</code> " + words(20) + "</p>")
            T.expect(inline.contains("flex-basis"), "inline code keeps its text")
        }

        T.suite("Filter: comments are not text") {
            let s = Standfirst.extract(from: "<!-- " + words(30) + " --><p>" + words(30) + "</p>")
            T.expect(s.hasPrefix("word01"), "a comment contributes nothing")
        }

        T.suite("Fallback: something beats nothing") {
            // Some items genuinely are one short line, and showing that beats
            // showing an empty card.
            let short = Standfirst.extract(from: "<p>New release: v2.1 out now.</p>")
            T.equal(short, "New release: v2.1 out now.", "a sub-threshold body is used whole")
            // A body that is only a tracking pixel has no text at all, so the
            // card must close up rather than show whitespace.
            T.equal(Standfirst.extract(from: "<img src=\"https://example.com/p.gif\">"), "",
                    "a body with no text yields nothing")
        }

        T.suite("Length: the lead's appetite bounds it") {
            // 200 words by default, and a paragraph that crosses the target is
            // cut at a sentence rather than taken whole — some feeds ship an
            // entire article as one <p>.
            let long = Standfirst.extract(from: "<p>" + sentences(60) + "</p>")
            let count = long.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            T.expect(count <= Standfirst.leadTargetWords + 25,
                     "cut near the target (got \(count) words for a target of \(Standfirst.leadTargetWords))")
            T.expect(long.hasSuffix("."), "cut at a sentence boundary, not mid-sentence")
        }

        T.suite("Sentences: abbreviations do not end one") {
            // Foundation's segmenter already knows this; a regex on full stops
            // would get it wrong on the first article that used one.
            let parts = Standfirst.sentences(of: "Dr. Smith went to the U.S. yesterday. Then home.")
            T.equal(parts.count, 2, "two sentences, not four")
            // Text with no sentence punctuation at all still yields one piece.
            T.equal(Standfirst.sentences(of: "no punctuation here").count, 1, "unpunctuated text is one sentence")
        }
    }

    // MARK: - Helpers

    private static func equal(_ input: String, _ want: String, _ what: String,
                              file: String = #fileID, line: Int = #line) {
        T.equal(Standfirst.decodeEntities(input), want, what, file: file, line: line)
    }

    /// `n` distinct words, so a paragraph clears the 15-word prose threshold
    /// and its content can still be identified in the result.
    private static func words(_ n: Int) -> String {
        (1...n).map { String(format: "word%02d", $0) }.joined(separator: " ")
    }

    /// `n` short sentences, for testing the cut at the word target.
    private static func sentences(_ n: Int) -> String {
        (1...n).map { "This is sentence number \($0) of the test paragraph." }.joined(separator: " ")
    }
}

/// The fetch path runs several `.*?` regexes with `dotMatchesLineSeparators`
/// over whatever a feed puts in `content:encoded`. An unclosed tag makes those
/// backtrack across the rest of the document, and a feed body has no natural
/// size, so one hostile item could stop the paper publishing at all.
enum StandfirstLimitTests {

    static func run() {
        T.suite("Standfirst: a body over the ceiling is clamped") {
            let huge = String(repeating: "<p>Some ordinary words in a paragraph.</p>",
                              count: 40_000)   // roughly 1.7 MB
            T.expect(huge.utf8.count > Standfirst.maxBodyBytes, "the fixture is over the ceiling")
            let started = Date()
            let out = Standfirst.extract(from: huge)
            let took = Date().timeIntervalSince(started)
            T.expect(!out.isEmpty, "it still yields a standfirst")
            T.expect(took < 2.0, "and does it promptly (took \(String(format: "%.2f", took))s)")
        }

        T.suite("Standfirst: an unclosed tag cannot run away") {
            // The shape that backtracks: an opening tag the pattern must find
            // a partner for, and megabytes of text after it that it never
            // will.
            let hostile = "<script>" + String(repeating: "a", count: 900_000)
                        + "<p>" + String(repeating: "word ", count: 60) + "</p>"
            let started = Date()
            _ = Standfirst.extract(from: hostile)
            let took = Date().timeIntervalSince(started)
            T.expect(took < 2.0, "bounded (took \(String(format: "%.2f", took))s)")
        }

        T.suite("Standfirst: an ordinary body is untouched") {
            // The clamp must not change any real result. Today's largest
            // extracted standfirst was 1,551 characters.
            let normal = "<p>" + String(repeating: "word ", count: 400) + "</p>"
            T.expect(normal.utf8.count < Standfirst.maxBodyBytes, "well under the ceiling")
            T.equal(Standfirst.extract(from: normal), Standfirst.extract(from: normal),
                    "stable")
            T.expect(!Standfirst.extract(from: normal).isEmpty, "and non-empty")
        }
    }
}

/// LinkeDOM does not decode character references inside `<title>`, so
/// Readability hands the reader `&mdash;` verbatim and nothing decoded it.
///
/// Measured on the page that reported it: the page's own `<title>` is
/// correctly single-encoded, so the three fixes I built for "the site
/// double-encodes" were all solving a problem that did not exist.
enum TitleDecodeTests {

    static func run() {
        T.suite("Title: references from the extractor are decoded") {
            // Verbatim from the real page, which is where the report came from.
            T.equal(Standfirst.decodeTitle(
                        "Old MacBook uses a mirror &mdash; 'agent-first' Omarchy Linux"),
                    "Old MacBook uses a mirror \u{2014} 'agent-first' Omarchy Linux",
                    "the reported case")
            T.equal(Standfirst.decodeTitle("LG denies claims &mdash; online investigation"),
                    "LG denies claims \u{2014} online investigation", "the other reported case")
            T.equal(Standfirst.decodeTitle("A &#8212; B"), "A \u{2014} B", "numeric")
            T.equal(Standfirst.decodeTitle("caf&eacute; society"), "café society", "accented")
            T.equal(Standfirst.decodeTitle("Marks &amp; Spencer"), "Marks & Spencer", "ampersand")
        }

        T.suite("Title: one pass, so escaped text stays escaped") {
            // The single left-to-right scan's own rule, which is what the
            // three abandoned second-pass versions kept breaking.
            T.equal(Standfirst.decodeTitle("&amp;lt;script&amp;gt;"), "&lt;script&gt;",
                    "text the source deliberately escaped is preserved")
            T.equal(Standfirst.decodeTitle("&amp;mdash;"), "&mdash;",
                    "and a genuinely double-encoded reference is shown as written")
        }

        T.suite("Title: nothing to decode is left alone") {
            for s in ["plain text", "A \u{2014} B", "Tom & Jerry",
                      "Marks & Spencer; and others", "AT&T; the sequel", "R&D;"] {
                T.equal(Standfirst.decodeTitle(s), s, "untouched: \(s)")
            }
        }
    }
}
