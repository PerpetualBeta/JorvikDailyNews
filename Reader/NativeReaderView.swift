import SwiftUI
import AppKit

/// Draws an article from `ReaderBlock`s, with no web view anywhere.
///
/// Every measurement here is lifted from `reader.css` rather than chosen, so
/// the two renderers agree: 18pt Charter at 1.7 line height in a 680-point
/// column, Didot headings, `#0057b7` links, and the dark-mode palette from the
/// same file. Where the stylesheet used a relative size the multiplier is kept
/// (`0.85em` for captions and code) so a change to the body size still carries.
///
/// It exists because `loadHTMLString` intermittently renders nothing at all on
/// both machines this app has been tested on, with no error of any kind, so a
/// perfectly extracted article still showed a blank page. Extraction stopped
/// needing WebKit in 1.4.5; this is the display half.
struct NativeReaderView: View {
    let article: ArticleExtractor.Article
    let blocks: [ReaderBlock]
    let sourceTitle: String
    let baseURL: URL
    /// The picture the paper already holds for this item, drawn above the
    /// article when the extracted text opens with none. See `ReaderLede`.
    var hero: URL? = nil

    /// The email link awaiting the reader's decision, if any.
    @State private var pendingEmail: MailtoLink?

    // MARK: Measurements, all from reader.css

    /// `fileprivate` rather than `private` so `InlineSVG` at the foot of this
    /// file can use the same measurements. One renderer, one column width.
    fileprivate enum Style {
        static let column: CGFloat = 680        // article max-width
        static let sidePadding: CGFloat = 32    // article padding
        static let topPadding: CGFloat = 56     // article margin-top
        static let bottomPadding: CGFloat = 96  // article margin-bottom

        static let body: CGFloat = 18           // font-size
        static let lineHeight: CGFloat = 1.7    // line-height
        static let paragraphGap: CGFloat = 1.1  // p margin-bottom, in em

        static let h1: CGFloat = 42
        static let h2: CGFloat = 28
        static let h3: CGFloat = 22
        static let h4: CGFloat = 18
        static let headingTopGap: CGFloat = 1.8 // h2/h3/h4 margin-top, in em
        static let headingBottomGap: CGFloat = 0.5

        static let bylineSize: CGFloat = 11
        static let bylineTracking: CGFloat = 2  // letter-spacing
        static let smallerScale: CGFloat = 0.85 // figcaption + code font-size

        static let mediaGap: CGFloat = 28       // img/blockquote/figure margins
        static let ruleGap: CGFloat = 40        // hr margin
        static let quoteBarWidth: CGFloat = 3
        static let quoteInset: CGFloat = 28
        static let listIndent: CGFloat = 24     // ~1.5em at 18pt is 27; 24 reads better
        static let listItemGap: CGFloat = 0.4   // li margin-bottom, in em
        static let codePadding: CGFloat = 16
        static let codeCorner: CGFloat = 4
        static let cellPadding: CGFloat = 8

        static let serif = firstAvailable(["Charter", "Iowan Old Style", "Palatino", "Georgia"])
        static let display = firstAvailable(["Didot", "Bodoni 72", "Georgia"])
        static let mono = firstAvailable(["SF Mono", "Menlo", "Monaco", "Courier New"])

        /// The first font on the list this machine actually has.
        ///
        /// The stylesheet lists fallbacks and a browser walks them; SwiftUI's
        /// `.custom` does not. It silently substitutes the **system** font for
        /// a name it cannot resolve, which for the code chain is a disaster:
        /// `SF Mono` does not resolve by that name on this Mac, so code blocks
        /// would have come out in a proportional face while the CSS renderer
        /// showed Menlo. Measured, not assumed — `NSFont(name:size:)` returns
        /// nil for "SF Mono" and resolves "Menlo" to Menlo-Regular.
        private static func firstAvailable(_ names: [String]) -> String {
            names.first { NSFont(name: $0, size: 12) != nil } ?? names[names.count - 1]
        }
    }

    /// The palette, both schemes, straight from the stylesheet's two halves.
    private enum Palette {
        static func background(_ dark: Bool) -> Color {
            dark ? Color(white: 0x11 / 255.0) : Color(white: 0xfa / 255.0)
        }
        static func text(_ dark: Bool) -> Color {
            dark ? Color(white: 0xed / 255.0) : Color(white: 0x1a / 255.0)
        }
        static func heading(_ dark: Bool) -> Color { dark ? .white : .black }
        static func link(_ dark: Bool) -> Color {
            dark ? Color(red: 0x8e / 255.0, green: 0xc0 / 255.0, blue: 1)
                 : Color(red: 0, green: 0x57 / 255.0, blue: 0xb7 / 255.0)
        }
        static func byline(_ dark: Bool) -> Color {
            dark ? Color(white: 0x9a / 255.0) : Color(white: 0x55 / 255.0)
        }
        static func caption(_ dark: Bool) -> Color {
            dark ? Color(white: 0xb0 / 255.0) : Color(white: 0x44 / 255.0)
        }
        static func rule(_ dark: Bool) -> Color {
            dark ? Color(white: 0x44 / 255.0) : Color(white: 0xcc / 255.0)
        }
        static func quoteBar(_ dark: Bool) -> Color {
            dark ? Color(white: 0xb8 / 255.0) : Color(white: 0x88 / 255.0)
        }
        static func codeBackground(_ dark: Bool) -> Color {
            dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        }
    }

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let lede {
                    // Above the first block, below the headline, which is where
                    // a newspaper puts it. Uncapped, like every other picture in
                    // the reader, so it keeps its own shape.
                    VStack(alignment: .leading, spacing: 10) {
                        OptionalImage(url: lede, maxHeight: nil, onFailure: nil)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, Style.mediaGap)
                }
                ForEach(blocks) { block in
                    view(for: block)
                }
            }
            .frame(maxWidth: Style.column, alignment: .leading)
            .padding(.horizontal, Style.sidePadding)
            .padding(.top, Style.topPadding)
            .padding(.bottom, Style.bottomPadding)
            .frame(maxWidth: .infinity)   // centre the column in the pane
        }
        .background(Palette.background(dark))
        .textSelection(.enabled)
        // Stated rather than inherited. The default action already opens the
        // browser, but leaving it implicit means a dead click has nothing to
        // look at: with this, the log says whether the click was received at
        // all, which separates "the link is not live" from "the browser did
        // not come forward".
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .sheet(item: $pendingEmail) { mail in
            EmailLinkSheet(mail: mail) { pendingEmail = nil }
        }
    }

    // MARK: Header

    /// The paper's own hero, when the extracted article opens without one.
    private var lede: URL? {
        ReaderLede.hero(hero,
                        blockKinds: blocks.map { $0.kind.rawValue },
                        blockSources: blocks.map { $0.src })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(bylineLine.uppercased())
                .font(.custom(Style.serif, size: Style.bylineSize))
                .tracking(Style.bylineTracking)
                .foregroundStyle(Palette.byline(dark))
            // Double-decoded where that cannot produce markup. See decodeTitle.
            Text(Standfirst.decodeTitle(article.title ?? sourceTitle))
                .font(.custom(Style.display, size: Style.h1))
                .foregroundStyle(Palette.heading(dark))
                .lineSpacing(Style.h1 * 0.15)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 40)   // article header margin-bottom
    }

    /// "SITE · BYLINE", matching what the HTML renderer builds.
    private var bylineLine: String {
        let site = article.siteName ?? sourceTitle
        guard let byline = article.byline, !byline.isEmpty else { return site }
        return "\(site) \u{00B7} \(byline)"
    }

    // MARK: Blocks

    @ViewBuilder
    private func view(for block: ReaderBlock) -> some View {
        switch block.kind {
        case .paragraph:
            prose(block.runs ?? [], size: Style.body,
                  lineSpacing: Style.body * (Style.lineHeight - 1))
                .padding(.bottom, Style.body * Style.paragraphGap)

        case .heading:
            let level = max(1, min(6, block.level ?? 2))
            prose(block.runs ?? [], size: headingSize(level), display: true,
                  lineSpacing: headingSize(level) * 0.25,
                  colour: Palette.heading(dark))
                .foregroundStyle(Palette.heading(dark))
                .padding(.top, Style.body * Style.headingTopGap)
                .padding(.bottom, Style.body * Style.headingBottomGap)

        case .image:
            picture(block)

        case .svg:
            inlineSVG(block)

        case .list:
            VStack(alignment: .leading, spacing: Style.body * Style.listItemGap) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Nested items are indented a full marker column each,
                        // and a nested bullet changes shape the way a printed
                        // list does rather than repeating the same dot.
                        Text(item.ordered ? "\(item.index)." : marker(depth: item.depth))
                            .font(.custom(Style.serif, size: Style.body))
                            .foregroundStyle(Palette.text(dark))
                            .frame(width: Style.listIndent, alignment: .trailing)
                            .padding(.leading, CGFloat(item.depth) * Style.listIndent)
                        prose(item.runs, size: Style.body,
                              lineSpacing: Style.body * (Style.lineHeight - 1))
                    }
                }
            }
            .padding(.bottom, Style.body * Style.paragraphGap)

        case .quote:
            HStack(alignment: .top, spacing: Style.quoteInset) {
                Palette.quoteBar(dark).frame(width: Style.quoteBarWidth)
                prose(block.runs ?? [], size: Style.body, italic: true,
                      lineSpacing: Style.body * (Style.lineHeight - 1))
            }
            .padding(.vertical, Style.mediaGap)

        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text ?? "")
                    .font(.custom(Style.mono, size: Style.body * Style.smallerScale))
                    .foregroundStyle(Palette.text(dark))
                    .lineSpacing(Style.body * Style.smallerScale * 0.5)
                    .padding(Style.codePadding)
                    .textSelection(.enabled)
            }
            .background(Palette.codeBackground(dark))
            .clipShape(RoundedRectangle(cornerRadius: Style.codeCorner))
            .padding(.bottom, Style.body * Style.paragraphGap)

        case .rule:
            Palette.rule(dark)
                .frame(height: 1)
                .padding(.vertical, Style.ruleGap)

        case .table:
            table(block)
        }
    }

    /// Bullet, ring, dash — the sequence a printed list uses as it nests.
    private func marker(depth: Int) -> String {
        let markers = ["\u{2022}", "\u{25E6}", "\u{2013}"]
        return markers[min(depth, markers.count - 1)]
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: Style.h1
        case 2: Style.h2
        case 3: Style.h3
        default: Style.h4
        }
    }

    // MARK: Runs

    /// A run of prose, drawn by TextKit only when it carries a link.
    ///
    /// The `.textSelection(.disabled)` boundary is the fix, not a loss of
    /// selection: `ProseText` contains its own selectable `NSTextView`. It
    /// keeps the reader-wide SwiftUI selection layer from reclaiming the
    /// cursor after TextKit has correctly chosen the pointing hand.
    @ViewBuilder
    private func prose(_ runs: [ReaderBlock.Run], size: CGFloat,
                       display: Bool = false, italic: Bool = false,
                       lineSpacing: CGFloat, colour: Color? = nil,
                       alignment: NSTextAlignment = .natural) -> some View {
        if runs.contains(where: { $0.target(relativeTo: baseURL) != nil }) {
            ProseText(
                attributed: appKitStyled(runs, size: size, display: display,
                                         italic: italic, lineSpacing: lineSpacing,
                                         colour: colour),
                linkColour: NSColor(Palette.link(dark)),
                alignment: alignment,
                onOpen: open
            )
            // End the ancestor's cursor ownership at this boundary. The
            // NSTextView remains selectable through `isSelectable = true`.
            .textSelection(.disabled)
        } else {
            styled(runs, size: size, display: display, italic: italic)
                .lineSpacing(lineSpacing)
        }
    }

    /// The AppKit equivalent of `styled`, kept explicit because SwiftUI Font
    /// and Color attributes do not bridge back into `NSAttributedString`.
    private func appKitStyled(_ runs: [ReaderBlock.Run], size: CGFloat,
                              display: Bool, italic: Bool,
                              lineSpacing: CGFloat, colour: Color?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let ink = NSColor(colour ?? Palette.text(dark))

        for run in runs {
            let family = run.code ? Style.mono : (display ? Style.display : Style.serif)
            let pointSize = run.code ? size * Style.smallerScale : size
            var font = NSFont(name: family, size: pointSize) ?? .systemFont(ofSize: pointSize)
            var traits: NSFontTraitMask = []
            if run.bold || display { traits.insert(.boldFontMask) }
            if run.italic || italic { traits.insert(.italicFontMask) }
            if !traits.isEmpty {
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: ink
            ]
            if let target = run.target(relativeTo: baseURL) {
                switch target {
                case .web(let url): attributes[.link] = url
                case .email(let mail): attributes[.link] = mail.original
                }
            }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
    }


    /// One paragraph as a single `Text`, so it wraps as prose.
    ///
    /// Built as an `AttributedString` rather than by adding `Text` values
    /// together, and that is not a tidying-up. A `Text` has no way to carry a
    /// link: `Text(run.text).foregroundColor(...).underline()` produces
    /// something that looks exactly like a link and does nothing at all when
    /// clicked, which is what the reader shipped with. The `.link` attribute
    /// exists only on `AttributedString`, and `Text` renders one as live.
    ///
    /// Still one `Text` at the end. An `HStack` of them would stop wrapping.
    private func styled(_ runs: [ReaderBlock.Run], size: CGFloat,
                        display: Bool = false, italic: Bool = false) -> Text {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            let family = run.code ? Style.mono : (display ? Style.display : Style.serif)
            let pointSize = run.code ? size * Style.smallerScale : size
            var font = Font.custom(family, size: pointSize)
            if run.bold || display { font = font.bold() }
            if run.italic || italic { font = font.italic() }
            piece.font = font

            if let target = run.target(relativeTo: baseURL) {
                switch target {
                case .web(let url): piece.link = url
                // The ORIGINAL mailto, not the rebuilt one. `open(_:)`
                // intercepts it and re-parses, and the sheet has to be able
                // to name the fields it is dropping — which `safeURL` has
                // already removed. Nothing opens this attribute directly.
                case .email(let mail): piece.link = mail.original
                }
                piece.foregroundColor = Palette.link(dark)
                piece.underlineStyle = .single
            } else {
                piece.foregroundColor = Palette.text(dark)
                // A link the article gave us that will not resolve is drawn as
                // ordinary text. Underlining something inert is the bug this
                // whole change is about, and a broken href must not reproduce
                // it in miniature.
            }
            out.append(piece)
        }
        return Text(out)
    }


    /// Where every link in the article ends up.
    ///
    /// A web address goes straight to the browser. An email address stops
    /// here: `mailto:` carries fields the reader cannot see — `bcc` to a
    /// harvesting address, a prefilled body — and a feed chooses every
    /// character of it, so it is shown before Mail is involved.
    private func open(_ url: URL) {
        if MailtoLink.isMailto(url), let mail = MailtoLink(url) {
            jdnLog("reader: an article link wants to email \(mail.recipients)"
                   + (mail.discarded.isEmpty ? "" : " (dropping \(mail.discarded.joined(separator: ", ")))"))
            pendingEmail = mail
            return
        }
        guard WebURL.isAllowed(url) else {
            jdnLog("reader: refused a link to \(url.scheme ?? "(no scheme)"): — not a web address")
            return
        }
        jdnLog("reader: following a link to \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    // MARK: Media

    @ViewBuilder
    private func picture(_ block: ReaderBlock) -> some View {
        if let src = block.src, let url = URL(string: src, relativeTo: baseURL)?.absoluteURL {
            VStack(alignment: .leading, spacing: 10) {
                OptionalImage(url: url, maxHeight: nil, onFailure: nil)
                    .frame(maxWidth: .infinity)
                if let caption = block.caption, !caption.isEmpty {
                    prose(caption, size: Style.body * Style.smallerScale, italic: true,
                          lineSpacing: 0, colour: Palette.caption(dark), alignment: .center)
                        .foregroundStyle(Palette.caption(dark))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, Style.mediaGap)
        }
    }

    /// An inline `<svg>`, drawn by AppKit rather than WebKit.
    ///
    /// `NSImage(data:)` takes SVG source and produces an `_NSSVGImageRep`;
    /// verified by rasterising one into a bitmap and counting painted pixels,
    /// including a case using `defs`, `clipPath` and a `clip-path="url(#…)"`
    /// reference, which is the shape real pages use.
    @ViewBuilder
    private func inlineSVG(_ block: ReaderBlock) -> some View {
        InlineSVG(block: block) { runs in
            prose(runs, size: Style.body * Style.smallerScale, italic: true,
                  lineSpacing: 0, colour: Palette.caption(dark))
                .foregroundStyle(Palette.caption(dark))
        }
    }

    @ViewBuilder
    private func table(_ block: ReaderBlock) -> some View {
        let rows = block.rows ?? []
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, runs in
                            prose(runs, size: Style.body * Style.smallerScale,
                                  lineSpacing: 0)
                                .padding(.horizontal, Style.cellPadding + 4)
                                .padding(.vertical, Style.cellPadding)
                                .frame(minWidth: 80, alignment: .leading)
                        }
                    }
                    Palette.rule(dark).frame(height: 1)
                }
            }
        }
        .padding(.vertical, Style.mediaGap)
    }
}

/// Where the SVG parse is allowed to block. Serial, because a page has few
/// diagrams and one thread cannot starve anything.
///
/// At file scope rather than inside `InlineSVG`, which is generic over its
/// caption view — and a generic type cannot hold a static stored property.
private let svgParseQueue = DispatchQueue(label: "cc.jorviksoftware.jdn.svg",
                                          qos: .userInitiated)

/// An inline `<svg>` from an article, parsed off the main actor and only once.
///
/// It used to call `NSImage(data:)` inside a `@ViewBuilder` reached from
/// `body`, uncached, so the parse re-ran on every body evaluation and ran on
/// whichever actor was drawing. Fine for a diagram, and not fine at all for
/// what an article can send: measured on the exact bytes this pipeline
/// produced, **240.1 KB of filter primitives took 31.05 seconds to draw and
/// 1,680 MB of resident memory, and painted nothing at all** — a frozen window
/// per body pass, from a file smaller than a photograph.
///
/// The walker now refuses a source over 64 KB. This re-checks rather than
/// trusting it, because the two are separate components — one JavaScript in a
/// bundled resource, one Swift — and a ceiling enforced in only one of them is
/// a ceiling one edit away from being gone.
///
/// **An earlier version of this comment said the walker's output is persisted
/// in the edition. It is not.** Checked 2026-09-11: an edition stores feed
/// items only — title, summary, link, picture — and holds no blocks at all,
/// so a `kind: svg` block exists only for as long as an article sheet is open.
/// Nothing on disk carries an un-checked SVG, and any reasoning that depends
/// on stored blocks is reasoning about something that does not exist.
private struct InlineSVG<Caption: View>: View {
    let block: ReaderBlock
    @ViewBuilder let caption: ([ReaderBlock.Run]) -> Caption

    @State private var image: NSImage?
    @State private var refused = false

    /// The same ceiling the walker applies, restated because the walker is
    /// JavaScript in a bundled resource and this is Swift: a ceiling enforced
    /// in only one of them is one edit away from being gone.
    private static var maxSource: Int { 64 * 1024 }

    /// The width this will be drawn at, and the height its own aspect ratio
    /// asks for. Used for the placeholder so the column does not jump as
    /// diagrams arrive.
    private var drawnSize: CGSize {
        let w = min(NativeReaderView.Style.column,
                    CGFloat(block.width ?? Double(NativeReaderView.Style.column)))
        guard let bw = block.width, let bh = block.height, bw > 0, bh > 0 else {
            return CGSize(width: w, height: w * 0.6)
        }
        return CGSize(width: w, height: w * CGFloat(bh / bw))
    }

    var body: some View {
        // **This must never be empty.** It used to be `Group { if let image … }`
        // with the parse in the `.task` below, which is a deadlock by
        // construction: SwiftUI does not run a `.task` attached to a view that
        // renders as `EmptyView`, so the image was never parsed, so the view
        // was never non-empty. Inline SVG therefore never drew at all, silently
        // and without a log line, from the day it was written until 2026-09-11.
        //
        // Proven rather than reasoned: a five-line SwiftUI app with two cases,
        // one `Group` empty until state arrives and one holding a `Color.clear`,
        // ran the task on the second and not the first.
        //
        // The placeholder also reserves the right height, so the column does
        // not jump as each diagram arrives.
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Never upscale past its own size, the same rule the
                    // masonry uses: a small mark drawn large is a blur.
                    .frame(maxWidth: drawnSize.width)
                if let runs = block.caption, !runs.isEmpty { caption(runs) }
            } else if refused {
                // Nothing: a refused diagram is not worth a notice in the
                // middle of an article, and the reason is in the log.
                Color.clear.frame(width: 1, height: 1)
            } else {
                Color.clear
                    .frame(width: drawnSize.width, height: drawnSize.height)
            }
        }
        .padding(.vertical, NativeReaderView.Style.mediaGap)
        .task(id: block.id) {
            guard image == nil, !refused else { return }
            guard let source = block.svg, source.utf8.count <= Self.maxSource else {
                refused = true
                jdnLog("reader: refused an inline SVG of \(block.svg?.utf8.count ?? 0) bytes"
                       + " — over the \(Self.maxSource) allowed")
                return
            }
            // The walker strips every external reference at capture time.
            // This is the second check, for the same reason the size ceiling
            // is restated: one rule, two components, and a rule held in only
            // one half is one edit from being gone.
            if let why = SVGSafety.refusal(for: source) {
                refused = true
                jdnLog("reader: refused an inline SVG — \(why)")
                return
            }
            // Off the main actor, and off the cooperative pool.
            //
            // `Task.detached` was the first version of this and it is the same
            // bug that `SaliencyCache.span` had: the detached task runs on
            // Swift Concurrency's cooperative pool, which is exactly as wide
            // as the core count, and `NSImage(data:)` on SVG source is a
            // synchronous parse that occupies its thread rather than yielding.
            // Measured on a hostile SVG this pipeline actually produced, that
            // parse-and-draw took **31 seconds**. Fourteen of those and the
            // app cannot schedule any async work at all — which is exactly
            // how a full edition of pictures wedged the whole app through
            // Vision.
            //
            // The source is capped at 64 KB in two places, so the realistic
            // cost is small. The queue is not about the cost; it is about
            // where a blocking call is allowed to block.
            let parsed = await withCheckedContinuation { continuation in
                svgParseQueue.async {
                    continuation.resume(returning: source.data(using: .utf8)
                        .flatMap(NSImage.init(data:)))
                }
            }
            guard !Task.isCancelled else { return }
            // A nil parse used to produce nothing at all: no image, no notice,
            // no log line. That is the failure this app has been bitten by four
            // times in one day, and it is not repeating here.
            if parsed == nil {
                refused = true
                jdnLog("reader: an inline SVG of \(source.utf8.count) bytes would not parse")
            }
            image = parsed
        }
    }
}
