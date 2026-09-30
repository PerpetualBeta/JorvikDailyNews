import AppKit
import SwiftUI

/// Keyboard scrolling for the paper and the reader: Home, End, Page Up, Page
/// Down, the space bar (shift-space goes back up) and the up and down arrows,
/// behaving the way a browser or any native Mac document does.
///
/// ## Why this exists
///
/// The paper used to make its SwiftUI `ScrollView` `.focusable()` on the belief
/// that Page Up, Page Down and space would then "fall through to the underlying
/// NSScrollView, which handles them natively". They did not: focusing the
/// SwiftUI view does not make the AppKit scroll view beneath it the responder
/// that receives those keys, so they reached nothing, anywhere in the app. Home
/// and End only worked on the paper because they were wired up by hand there,
/// and the reader had no keyboard handling at all.
///
/// ## How it works
///
/// Each of the two vertical scroll views marks itself with a `ScrollViewAnchor`,
/// an invisible AppKit view in its content that finds its enclosing
/// `NSScrollView` and registers it here. One key monitor for the window then
/// sends each key to whichever is in front: the reader while an article is
/// open, since it is laid over the still-mounted paper, and the paper
/// otherwise. One path, so the two cannot behave differently.
///
/// A page is the visible height less `verticalPageScroll`, AppKit's own figure
/// for how much of the previous page to keep in view, so paging leaves the same
/// overlap a native scroll view does rather than a number chosen here.
@MainActor
final class KeyboardScroller {
    static let shared = KeyboardScroller()

    enum Role { case paper, reader }

    private weak var paper: NSScrollView?
    private weak var reader: NSScrollView?
    private var monitor: Any?

    /// How far one press of an arrow key moves, in points. A feel setting, not
    /// a derived one, which is why it is a knob:
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews arrowScrollDistance -float 60
    private var lineDistance: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "arrowScrollDistance")
        return stored > 0 ? stored : 40
    }

    /// KeyNav's key handler. Consulted before scrolling, only while the paper
    /// is in front. Returns true for a key it used.
    var paperKeyHandler: ((NSEvent) -> Bool)?

    /// The part of the paper's content currently on screen, in the paper's
    /// content coordinates (top-left origin).
    func paperVisibleRect() -> CGRect? {
        guard let paper, let document = paper.documentView else { return nil }
        let clip = paper.contentView.bounds
        let maxOffset = max(0, document.frame.height - clip.height)
        let top = document.isFlipped ? clip.origin.y : maxOffset - clip.origin.y
        return CGRect(x: clip.origin.x, y: top, width: clip.width, height: clip.height)
    }

    /// Scroll the paper by the least amount that shows `rect` whole, with `top`
    /// and `bottom` points clear around it. Nothing moves if it already is. A
    /// story taller than the space available is shown from its top.
    func revealInPaper(_ rect: CGRect, top: CGFloat, bottom: CGFloat) {
        guard let paper, let document = paper.documentView,
              let visible = paperVisibleRect() else { return }
        let clip = paper.contentView
        let maxOffset = max(0, document.frame.height - visible.height)
        var wanted = visible.minY
        if rect.height + top + bottom > visible.height || rect.minY - top < visible.minY {
            wanted = rect.minY - top
        } else if rect.maxY + bottom > visible.maxY {
            wanted = rect.maxY + bottom - visible.height
        }
        let clamped = min(max(wanted, 0), maxOffset)
        guard abs(clamped - visible.minY) > 0.5 else { return }
        let y = document.isFlipped ? clamped : maxOffset - clamped
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        paper.reflectScrolledClipView(clip)
    }

    func register(_ scrollView: NSScrollView, as role: Role) {
        switch role {
        case .paper: paper = scrollView
        case .reader: reader = scrollView
        }
        installMonitorIfNeeded()
    }

    func unregister(_ scrollView: NSScrollView, as role: Role) {
        switch role {
        case .paper: if paper === scrollView { paper = nil }
        case .reader: if reader === scrollView { reader = nil }
        }
    }

    // MARK: - Keys

    private enum Move { case lineUp, lineDown, pageUp, pageDown, top, bottom }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let target = self.target(for: event) else { return event }
            // KeyNav goes first while the paper is in front, so that in KeyNav
            // mode the arrows move the highlight instead of scrolling. It never
            // sees keys while an article is open: there the reader's own keys,
            // Esc for Back to Paper among them, are left alone.
            if target === self.paper, let keyNav = self.paperKeyHandler, keyNav(event) {
                return nil
            }
            guard let move = self.move(for: event) else { return event }
            self.perform(move, on: target)
            return nil
        }
    }

    private func move(for event: NSEvent) -> Move? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        // Shift is only meaningful with space. Command, option and control
        // belong to other shortcuts: command-left and command-right turn pages.
        switch event.keyCode {
        case 49 where mods == .shift: return .pageUp      // shift-space
        case 49 where mods.isEmpty:   return .pageDown    // space
        case 116 where mods.isEmpty:  return .pageUp      // Page Up
        case 121 where mods.isEmpty:  return .pageDown    // Page Down
        case 115 where mods.isEmpty:  return .top         // Home
        case 119 where mods.isEmpty:  return .bottom      // End
        case 126 where mods.isEmpty:  return .lineUp      // up arrow
        case 125 where mods.isEmpty:  return .lineDown    // down arrow
        default: return nil
        }
    }

    /// The scroll view in front, or nil if the key belongs to something else.
    private func target(for event: NSEvent) -> NSScrollView? {
        let front = (reader?.window != nil ? reader : nil) ?? paper
        guard let front, let window = front.window,
              event.window === window, window.isKeyWindow,
              window.attachedSheet == nil else { return nil }
        // Leave typing alone. The field editor of any text field, and any
        // editable text view, keeps its keys. A non-editable text view does
        // not: the reader draws linked paragraphs as NSTextView, and clicking
        // into one must not stop the page from scrolling.
        if let text = window.firstResponder as? NSTextView, text.isEditable || text.isFieldEditor {
            return nil
        }
        return front
    }

    // MARK: - Scrolling

    private func perform(_ move: Move, on scrollView: NSScrollView) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds.height
        let maxOffset = max(0, document.frame.height - visible)
        let page = max(visible - scrollView.verticalPageScroll, lineDistance)

        // Distance travelled downwards through the document, whichever way up
        // the document view's coordinates run.
        let flipped = document.isFlipped
        let current = flipped ? clip.bounds.origin.y : maxOffset - clip.bounds.origin.y
        let wanted: CGFloat
        switch move {
        case .lineUp:   wanted = current - lineDistance
        case .lineDown: wanted = current + lineDistance
        case .pageUp:   wanted = current - page
        case .pageDown: wanted = current + page
        case .top:      wanted = 0
        case .bottom:   wanted = maxOffset
        }
        let clamped = min(max(wanted, 0), maxOffset)
        guard clamped != current else { return }
        let origin = NSPoint(x: clip.bounds.origin.x, y: flipped ? clamped : maxOffset - clamped)

        // Moves at once, the way a native Mac document view pages. An animated
        // move was tried first and does nothing: SwiftUI's clip view ignores
        // `animator().setBoundsOrigin`, so every key computed the right place
        // and the view stayed where it was. Measured in a harness against this
        // file; `scroll(to:)` lands exactly.
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)

        if clamped == maxOffset {
            followTheEnd(of: scrollView, lastMax: maxOffset, rounds: 0)
        }
    }
}

extension KeyboardScroller {
    /// Keep going until the bottom really is the bottom.
    ///
    /// The reader's content is a `LazyVStack`: SwiftUI lays out only what is
    /// near the screen and estimates the height of the rest. Scrolling to the
    /// end of that estimate makes SwiftUI lay out the real last paragraphs,
    /// they are usually taller than estimated, and the document grows under
    /// you. Measured on an article-shaped harness: End landed at 26,868 of what
    /// had become 27,064, so 196 points short, which is what End looked like in
    /// the reader. The paper is not lazy and never showed it.
    ///
    /// So after landing on the bottom, lay the document out again and, if it
    /// grew, follow it down, until its height stops changing. That happens as
    /// soon as the last paragraphs are real, a round or two in practice. The
    /// round limit is only a guard against content that never settles.
    fileprivate func followTheEnd(of scrollView: NSScrollView, lastMax: CGFloat, rounds: Int) {
        guard rounds < 20 else { return }
        DispatchQueue.main.async {
            guard let document = scrollView.documentView else { return }
            document.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            let newMax = max(0, document.frame.height - clip.bounds.height)
            guard abs(newMax - lastMax) > 0.5 else { return }
            let y = document.isFlipped ? newMax : 0
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            self.followTheEnd(of: scrollView, lastMax: newMax, rounds: rounds + 1)
        }
    }
}

/// Marks the vertical scroll view it sits in for `KeyboardScroller`. Place it as
/// a background of the scroll view's content.
struct ScrollViewAnchor: NSViewRepresentable {
    let role: KeyboardScroller.Role

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.role = role
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.role = role
    }

    /// Registers itself as soon as it can find its scroll view, and again if
    /// that ever changes. It tries on every move and layout pass rather than
    /// only when it joins the window, in case SwiftUI has not yet placed it
    /// inside the scroll view at that moment. Defensive: in the harness the
    /// first attempt already found it, but the reader's content is lazy and was
    /// not what the harness measured.
    final class AnchorView: NSView {
        var role: KeyboardScroller.Role = .paper
        private weak var registered: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        override func layout() {
            super.layout()
            attach()
        }

        private func attach() {
            let current = window == nil ? nil : enclosingScrollView
            guard current !== registered else { return }
            if let registered { KeyboardScroller.shared.unregister(registered, as: role) }
            registered = current
            if let current { KeyboardScroller.shared.register(current, as: role) }
        }
    }
}
