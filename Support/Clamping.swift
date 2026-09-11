import Foundation

/// Ceilings that count what the consumer counts.
///
/// **Every stored-string ceiling in this app used to count Swift
/// `Character`s, and not one consumer of those strings counts the same
/// thing.** A `Character` is a grapheme cluster, which has no upper bound in
/// size: one base letter plus 40,000 combining accents is a single
/// `Character`. Measured on this toolchain:
///
/// - `String(title.prefix(500))` on combining marks: **1 `Character`,
///   80,000 bytes**, against a ceiling written as 500.
/// - 65,000 clusters of `a` plus 200 × U+0301: 65,000 `Character`s,
///   **13,065,000 UTF-16 units**, 26 MB of UTF-8. That passed a
///   `maxBlockChars` test written as 65,536 and reached `NSLayoutManager`,
///   which measured it in about 3 s on the main thread.
/// - `"https://e.example/?q=a"` plus 30,000 U+0301: 26 `Character`s in,
///   `absoluteString` **180,026 characters** out, against a 2,048 ceiling.
///
/// So the unit here is the UTF-16 code unit: it is what `NSLayoutManager`
/// lays out, what `JSONSerialization` counts, and what `String.length` means
/// in the walker's JavaScript, which is the other half of every one of these
/// rules. `InlineSVG.maxSource` already counted `utf8`, which is why it was
/// the one ceiling sweep 3 did not find a way through.
extension String {

    /// What this string costs, in the unit its consumers measure.
    var storedLength: Int { utf16.count }

    /// This string cut to at most `limit` UTF-16 code units.
    ///
    /// Cut on a **Unicode scalar** boundary, never mid-scalar, so the result
    /// can never end in a lone surrogate. That matters beyond tidiness: the
    /// walker's JavaScript cut by raw UTF-16 index, `JSON.stringify` happily
    /// emitted the resulting `\\ud83d`, and `JSONDecoder` then rejected the
    /// **entire article** with "Missing low code point in surrogate pair" —
    /// so one emoji landing on the ceiling turned a page that extracted
    /// perfectly into no article at all.
    ///
    /// Grapheme clusters may be split. That is deliberate: a cluster has no
    /// bounded size, so honouring it is what the ceilings were failing to do.
    func clamped(toUTF16 limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard utf16.count > limit else { return self }
        var out = String.UnicodeScalarView()
        var used = 0
        for scalar in unicodeScalars {
            let width = UTF16.width(scalar)
            if used + width > limit { break }
            out.append(scalar)
            used += width
        }
        return String(out)
    }
}
