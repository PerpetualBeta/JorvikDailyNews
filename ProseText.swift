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
            // The rects are computed from the layout, so they are stale the
            // moment the text is replaced.
            view.window?.invalidateCursorRects(for: view)
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
        override func resetCursorRects() {
            super.resetCursorRects()
            guard let storage = textStorage,
                  let manager = layoutManager,
                  let container = textContainer,
                  storage.length > 0
            else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.link, in: whole) { value, range, _ in
                guard value != nil else { return }
                // A link can wrap, so it may occupy several line fragments and
                // therefore several rects. One rect per fragment, or the hand
                // appears over the blank end of a line.
                let glyphs = manager.glyphRange(forCharacterRange: range,
                                                actualCharacterRange: nil)
                manager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                in: container) { rect, _ in
                    self.addCursorRect(rect.offsetBy(dx: self.textContainerOrigin.x,
                                                dy: self.textContainerOrigin.y),
                                  cursor: .pointingHand)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpen: (URL) -> Void
        init(onOpen: @escaping (URL) -> Void) { self.onOpen = onOpen }

        func textView(_ view: NSTextView, clickedOnLink link: Any,
                      at charIndex: Int) -> Bool {
            let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            onOpen(url)
            return true    // handled; AppKit must not also open it
        }
    }
}
