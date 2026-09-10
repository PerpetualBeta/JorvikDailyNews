import AppKit
import SwiftUI

/// Link-bearing prose drawn by TextKit.
///
/// SwiftUI's `Text` makes an attributed-string link clickable, but its
/// selectable-text layer owns the I-beam for the whole run. `NSTextView`
/// lays out, selects, hit-tests and draws the same text, so it can give link
/// glyphs their standard pointing-hand cursor without estimating where the
/// SwiftUI renderer put them.
///
/// The caller deliberately applies `.textSelection(.disabled)` at the
/// representable boundary. That does not disable selection here — this text
/// view is selectable itself. It prevents the ancestor SwiftUI selection
/// scope from registering a competing cursor over the AppKit view. This is
/// significant while the reader is an overlay on the still-mounted paper:
/// without the boundary, the hand is immediately replaced by the I-beam.
struct ProseText: NSViewRepresentable {
    let attributed: NSAttributedString
    let linkColour: NSColor
    var alignment: NSTextAlignment = .natural
    var onOpen: (URL) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = LinkTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        // The article decides what is a link. Automatic detection would style
        // URL-shaped prose that the source did not mark up.
        view.isAutomaticLinkDetectionEnabled = false
        view.delegate = context.coordinator
        configureLinks(in: view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onOpen = onOpen
        configureLinks(in: view)
        if view.textStorage?.isEqual(to: attributed) != true {
            view.textStorage?.setAttributedString(attributed)
            // SwiftUI can run this update before the representable has a
            // window. AppKit may then cache cursor rects for the empty text
            // view and never discover the link added here. Defer invalidation
            // until attachment so those rects are rebuilt from the real text.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.invalidateCursorRects(for: view)
            }
        }
        view.alignment = alignment
    }

    /// The height needed at the width proposed by SwiftUI.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView,
                      context: Context) -> CGSize? {
        guard let container = nsView.textContainer,
              let manager = nsView.layoutManager else { return nil }
        let width = proposal.width ?? container.containerSize.width
        guard width > 0, width < .greatestFiniteMagnitude else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: manager.usedRect(for: container).height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    /// A distinct AppKit view class keeps SwiftUI from applying the generic
    /// selectable-text cursor behavior it installs for a plain `NSTextView`.
    /// Its explicit cursor rectangles also cover the case where the pointer
    /// is already over the view when SwiftUI attaches it.
    private final class LinkTextView: NSTextView {
        private var linkTrackingArea: NSTrackingArea?

        override func resetCursorRects() {
            super.resetCursorRects()
            guard let storage = textStorage,
                  let manager = layoutManager,
                  let container = textContainer,
                  storage.length > 0 else { return }

            let whole = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.link, in: whole) { value, range, _ in
                guard value != nil else { return }
                let glyphs = manager.glyphRange(forCharacterRange: range,
                                                actualCharacterRange: nil)
                // One rectangle per occupied line fragment. A single bounding
                // box would put the hand over the blank tail of a wrapped link.
                manager.enumerateEnclosingRects(
                    forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    self.addCursorRect(
                        rect.offsetBy(dx: self.textContainerOrigin.x,
                                      dy: self.textContainerOrigin.y),
                        cursor: .pointingHand
                    )
                }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
                          .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            linkTrackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) {
            if link(under: convert(event.locationInWindow, from: nil)) {
                NSCursor.pointingHand.set()
            } else {
                super.cursorUpdate(with: event)
            }
        }

        override func mouseMoved(with event: NSEvent) {
            if link(under: convert(event.locationInWindow, from: nil)) {
                NSCursor.pointingHand.set()
            } else {
                super.mouseMoved(with: event)
            }
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            NSCursor.arrow.set()
        }

        /// Whether a point is on a link glyph rather than merely on the same
        /// line. TextKit's glyph lookup clamps misses to the nearest glyph, so
        /// both the through-glyph fraction and the glyph box must agree.
        private func link(under point: NSPoint) -> Bool {
            guard let manager = layoutManager,
                  let container = textContainer,
                  let storage = textStorage,
                  storage.length > 0 else { return false }
            let origin = textContainerOrigin
            let location = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            var fraction: CGFloat = 0
            let glyph = manager.glyphIndex(for: location, in: container,
                                           fractionOfDistanceThroughGlyph: &fraction)
            guard fraction < 1 else { return false }
            let box = manager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: container
            )
            guard box.contains(location) else { return false }
            let character = manager.characterIndexForGlyph(at: glyph)
            guard character < storage.length else { return false }
            return storage.attribute(.link, at: character, effectiveRange: nil) != nil
        }
    }

    private func configureLinks(in view: NSTextView) {
        view.linkTextAttributes = [
            .foregroundColor: linkColour,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpen: (URL) -> Void

        init(onOpen: @escaping (URL) -> Void) {
            self.onOpen = onOpen
        }

        func textView(_ view: NSTextView, clickedOnLink link: Any,
                      at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            onOpen(url)
            return true
        }
    }
}
