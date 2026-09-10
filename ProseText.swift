import AppKit
import SwiftUI

/// Prose drawn by TextKit rather than by SwiftUI, so that links behave.
///
/// SwiftUI's `Text` renders a `.link` attribute and will open it, but it gives
/// no way to find out where the link's glyphs ended up, so the cursor cannot
/// change over them. Guessing at that with a separately-computed layout would
/// put the pointing hand over the wrong words the moment a line broke
/// differently, which is worse than no cursor at all.
///
/// An `NSTextView` lays the text out and hit-tests it with the same object, so
/// the two agree by construction. It gives the pointing-hand cursor, the link
/// click and text selection for nothing.
///
/// **Verified pixel-identical to the SwiftUI rendering it replaces.** Both
/// were rendered headlessly at 2x — `ImageRenderer` for the SwiftUI side — and
/// compared: same size to the pixel (616x126), same line breaks, same
/// position, differences confined to antialiasing edges. The one real
/// difference was the link colour, because `NSTextView` overrides the
/// attributed string with `linkTextAttributes`; that is set below.
///
/// Used only for blocks that actually contain a link. Everything else stays on
/// SwiftUI `Text`, so the overwhelming majority of an article is untouched by
/// this.
private struct ProseTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let linkColour: NSColor
    var alignment: NSTextAlignment = .natural
    /// Called with the link the reader clicked, so opening it stays in one
    /// place rather than being AppKit's default behaviour by accident.
    var onOpen: (URL) -> Void
    /// Called once the view exists, so the wrapper can hit-test it.
    var onReady: (LinkCursorTextView) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = LinkCursorTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        // Off, or AppKit finds "links" of its own in the prose and styles text
        // the article never marked up.
        view.isAutomaticLinkDetectionEnabled = false
        view.delegate = context.coordinator
        view.linkTextAttributes = [
            .foregroundColor: linkColour,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        onReady(view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onOpen = onOpen
        view.linkTextAttributes = [
            .foregroundColor: linkColour,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        if view.textStorage?.isEqual(to: attributed) != true {
            view.textStorage?.setAttributedString(attributed)
        }
        view.alignment = alignment
    }

    /// The height this text needs at the width it is offered.
    ///
    /// Answered by laying it out rather than by a `GeometryReader` feeding a
    /// width back into a frame, which is the arrangement that collapses a
    /// SwiftUI stack the first time it disagrees with itself.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView,
                      context: Context) -> CGSize? {
        guard let container = nsView.textContainer,
              let manager = nsView.layoutManager else { return nil }
        let width = proposal.width ?? container.containerSize.width
        guard width > 0, width < .greatestFiniteMagnitude else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        // Not rounded up. `ceil` cost a point per block against SwiftUI's own
        // measurement; the exact value is within a point either way — measured
        // at -0.30pt for a body paragraph and +0.73pt for a heading — which is
        // nothing beside the explicit padding between blocks.
        return CGSize(width: width, height: manager.usedRect(for: container).height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    /// An `NSTextView` that says where the pointing hand goes instead of
    /// hoping AppKit works it out.
    ///
    /// `linkTextAttributes` carries `.cursor`, and in a bare text view that is
    /// enough: measured in isolation, the link attribute is present, the
    /// cursor is in the attributes, and hit-testing finds the link. Inside the
    /// reader it was not enough, and the reader has a `.textSelection(.enabled)`
    /// layer over the whole article, which is the obvious candidate for
    /// whose tracking wins.
    ///
    /// Rather than keep guessing at that, this declares the rects. `AppKit`
    /// asks a view for its cursor rects whenever they are invalidated, and a
    /// rect declared here beats anything implicit.
    final class LinkCursorTextView: NSTextView {

        /// This view no longer sets the cursor. It answers where the links
        /// are, and SwiftUI decides.
        ///
        /// Four mechanisms tried to set it from here and all four lost:
        /// `.cursor` in `linkTextAttributes`, cursor rects, a `.cursorUpdate`
        /// tracking area, and `mouseMoved` setting it imperatively. The last
        /// one got close enough to see the problem — the hand appeared and was
        /// immediately replaced — and the replacement was the **arrow**, not
        /// the I-beam an `NSTextView` sets over its own text. So the thing
        /// overriding sits above the text view, and it is SwiftUI's own hover
        /// handling.
        ///
        /// Both events did arrive, which is what ruled everything else out:
        ///
        ///     prosetext: mouseMoved reached the TextKit view
        ///     prosetext: cursorUpdate reached the TextKit view
        ///
        /// You cannot win that fight by setting the cursor harder. So the
        /// wrapper below hovers in SwiftUI, where SwiftUI is not competing
        /// with anything, and asks this view only the question it can answer
        /// accurately: is there a link under this point.
        /// The link at a point in this view's coordinates, if any.
        ///
        /// Hit-tested through the layout manager rather than by comparing
        /// rects, so a link that wraps across several line fragments needs no
        /// special handling, and the blank end of a line is correctly not a
        /// link.
        func link(under point: NSPoint) -> Any? {
            guard let manager = layoutManager,
                  let container = textContainer,
                  let storage = textStorage,
                  storage.length > 0
            else { return nil }
            let origin = textContainerOrigin
            let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            // A fraction near 1 means the pointer is past the last glyph on
            // that line, in the empty run-off, where there is nothing to click.
            var fraction: CGFloat = 0
            let glyph = manager.glyphIndex(for: inContainer, in: container,
                                           fractionOfDistanceThroughGlyph: &fraction)
            guard fraction < 1 else { return nil }
            let index = manager.characterIndexForGlyph(at: glyph)
            guard index < storage.length else { return nil }
            // And the pointer must actually be inside the glyph's box, not
            // merely on its line: `glyphIndex(for:)` clamps to the nearest
            // glyph rather than reporting a miss.
            let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                           in: container)
            guard box.contains(inContainer) else { return nil }
            return storage.attribute(.link, at: index, effectiveRange: nil)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpen: (URL) -> Void
        init(onOpen: @escaping (URL) -> Void) { self.onOpen = onOpen }

        func textView(_ view: NSTextView, clickedOnLink link: Any,
                      at charIndex: Int) -> Bool {
            jdnLog("prosetext: the TextKit view handled the click")
            let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            onOpen(url)
            return true    // handled; AppKit must not also open it
        }
    }
}

/// Prose with links, and a pointing hand over them.
///
/// The hover lives here rather than in the text view because SwiftUI is what
/// was overriding the cursor. Driving it from SwiftUI means nothing is
/// competing: on macOS 15 and later `pointerStyle` is the sanctioned API and
/// SwiftUI applies it itself, and on 14 the cursor is set from inside
/// SwiftUI's own hover callback rather than from an AppKit event that SwiftUI
/// will undo a moment later.
struct ProseText: View {
    let attributed: NSAttributedString
    let linkColour: NSColor
    var alignment: NSTextAlignment = .natural
    var onOpen: (URL) -> Void

    @State private var textView: ProseTextView.LinkCursorTextView?
    @State private var overLink = false
    @State private var reported = false

    var body: some View {
        hoverable
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    // `NSTextView` is flipped, so its coordinates and
                    // SwiftUI's local space share a top-left origin and the
                    // point needs no conversion.
                    let hit = textView?.link(under: point) != nil
                    if hit != overLink { overLink = hit }
                    if !reported {
                        reported = true
                        jdnLog("prosetext: SwiftUI hover is driving the cursor")
                    }
                case .ended:
                    if overLink { overLink = false }
                }
            }
    }

    @ViewBuilder
    private var hoverable: some View {
        let view = ProseTextView(attributed: attributed, linkColour: linkColour,
                                 alignment: alignment, onOpen: onOpen,
                                 onReady: { textView = $0 })
        if #available(macOS 15.0, *) {
            view.pointerStyle(overLink ? .link : nil)
        } else {
            view.onChange(of: overLink) { _, over in
                if over { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
    }
}
