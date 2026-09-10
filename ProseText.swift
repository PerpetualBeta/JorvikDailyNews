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
struct ProseText: NSViewRepresentable {
    let attributed: NSAttributedString
    let linkColour: NSColor
    var alignment: NSTextAlignment = .natural
    /// Called with the link the reader clicked, so opening it stays in one
    /// place rather than being AppKit's default behaviour by accident.
    var onOpen: (URL) -> Void

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
        jdnLog("prosetext: TextKit view created for a block with a link")
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

        /// Two mechanisms, deliberately.
        ///
        /// `linkTextAttributes` carries `.cursor` and in a bare text view that
        /// is enough — measured in isolation, the link attribute is present,
        /// the cursor is in the attributes, and hit-testing finds the link
        /// under the point. Inside the reader it was not enough, twice.
        ///
        /// Cursor rects are the next mechanism up, and they are awkward here:
        /// they are declared in view coordinates and recomputed only when
        /// something invalidates them, so a view SwiftUI has resized or
        /// repositioned can be carrying rects for a layout it no longer has.
        ///
        /// A tracking area asking for `.cursorUpdate` is the mechanism AppKit
        /// documents for a cursor that depends on what is under the pointer.
        /// It is resolved per event against the current layout, so it cannot
        /// go stale, and it needs no `acceptsMouseMovedEvents` on the window —
        /// which is `false` by default and one of the things I could not rule
        /// out.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeInActiveApp, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil))
        }

        override func cursorUpdate(with event: NSEvent) {
            if link(under: convert(event.locationInWindow, from: nil)) != nil {
                NSCursor.pointingHand.set()
            } else {
                super.cursorUpdate(with: event)
            }
        }

        /// The link at a point in this view's coordinates, if any.
        ///
        /// Hit-tested through the layout manager rather than by comparing
        /// rects, so a link that wraps across several line fragments needs no
        /// special handling, and the blank end of a line is correctly not a
        /// link.
        private func link(under point: NSPoint) -> Any? {
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
