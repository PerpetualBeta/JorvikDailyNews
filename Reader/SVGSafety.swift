import Foundation

/// A last look at an SVG before `NSImage(data:)` is handed it.
///
/// The walker sanitises at capture time, which is where the DOM is and so where
/// the job is done properly. This is the second check, for the same reason
/// `InlineSVG` re-checks the size ceiling: the two are separate components, one
/// JavaScript in a bundled resource and one Swift, and a rule enforced in only
/// one of them is one edit away from being gone. A security boundary worth
/// having is worth holding in both halves.
///
/// **It is not about stored blocks.** An earlier version of this said editions
/// on disk carry raw SVG. They do not — checked 2026-09-11, an edition stores
/// feed items only and holds no blocks — so the second check earns its place on
/// defence in depth alone, which is a weaker argument than the one first given
/// and still a sufficient one.
///
/// **It refuses rather than repairs.** Repairing needs a parser, and reaching
/// for one here would put a second XML parser in the app to defend against the
/// first. What reaches this point and still looks dangerous came from an old
/// edition, so refusing costs one diagram in one day's paper.
///
/// Foundation only, no DOM, so the suite can exercise it directly.
enum SVGSafety {

    /// Why an SVG will not be drawn, or nil when it is fine.
    static func refusal(for source: String) -> String? {
        let s = source.lowercased()

        // **A namespace prefix must not be a way past this.** `<svg:script>`
        // matched none of the substring tests these replaced, and matched
        // nothing in the walker's drop-list either, so a prefixed script
        // survived both halves.
        //
        // `<` then an optional `prefix:` then the local name.
        for (name, description) in [("script", "it contains a script element"),
                                    ("foreignobject", "it contains a foreignObject"),
                                    ("iframe", "it contains an iframe"),
                                    // **A filter sizes the rasteriser's buffer
                                    // from its own region**, stated either as
                                    // a percentage of the object bounding box
                                    // or, under `userSpaceOnUse`, in absolute
                                    // units with no relationship to the
                                    // viewBox. So `MAX_SVG_SIDE` bounds two
                                    // numbers that do not decide the work:
                                    // measured at a constant 247 bytes with an
                                    // ordinary `width`, `height` and
                                    // `viewBox`, 12.39 s and 4.6 GB at a
                                    // region of 60,000, and the review
                                    // measured 10.06 GB and a SIGKILL at
                                    // 200,000. `mask` carries the same
                                    // attributes.
                                    ("filter", "it contains a filter"),
                                    ("mask", "it contains a mask")] {
            if s.range(of: "<([a-z0-9_.-]+:)?" + name + "\\b",
                       options: .regularExpression) != nil {
                return description
            }
        }
        if s.contains("@import") { return "its stylesheet imports another" }

        // An event handler: `onload=`, `onclick=`, `onbegin=`, with any amount
        // of space around the equals sign.
        if s.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) != nil {
            return "it carries an event handler"
        }
        // The attribute form, which reaches the same region without the
        // element: `<rect filter="url(#f)">` where `#f` came from an earlier
        // block, or from a `<defs>` the walker kept.
        if s.range(of: #"\s(filter|mask)\s*=\s*["']?url\("#, options: .regularExpression) != nil {
            return "it applies a filter or a mask"
        }

        // Any reference with a scheme other than data:. Fragment references
        // (`#id`) and relative ones have no scheme and so do not match, which
        // is deliberate: `<use href="#icon">` is how real diagrams are built.
        // **Every reference, not the first one.** `range(of:options:)` returns
        // only the first match, and this then asked whether *that* match was a
        // `data:` URI — so a harmless `data:` reference placed before a hostile
        // `http:` one short-circuited the whole check. Verified: the pair was
        // allowed, and the same markup without the leading `data:` was refused.
        //
        // The negative lookahead asks the question directly: a reference whose
        // scheme is anything other than `data:`. There is no first-match
        // problem left to have, because there is nothing to inspect afterwards.
        if s.range(of: #"(href|src)\s*=\s*['"]?\s*(?!data:)[a-z][a-z0-9+.-]*:"#,
                   options: .regularExpression) != nil {
            return "it references something outside itself"
        }
        if s.range(of: #"url\(\s*['"]?\s*(?!data:)[a-z][a-z0-9+.-]*:"#,
                   options: .regularExpression) != nil {
            return "a url() references something outside itself"
        }
        // A protocol-relative reference has no scheme, so the tests above miss
        // it entirely: `url(//evil/x.css)` and `href="//evil/x.png"` both fetch.
        if s.range(of: #"url\(\s*['"]?\s*//"#, options: .regularExpression) != nil {
            return "a url() references another host"
        }
        if s.range(of: #"(href|src)\s*=\s*['"]?\s*//"#, options: .regularExpression) != nil {
            return "it references another host"
        }
        return nil
    }

}
