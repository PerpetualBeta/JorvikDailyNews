import AppKit
import SwiftUI

// KeyNav: moving a highlight through the paper's stories with the keyboard.
//
// Tab turns it on and highlights the first story on the page, the lead on the
// front page. The arrows move the highlight, Return opens the highlighted story
// exactly as a click would, and Esc turns it off. See `KeyNavController` for
// how it fits around the reader and the other keys.

/// Where every story on the current page sits, read from the stories
/// themselves at the moment it is needed.
///
/// Each story carries an invisible AppKit view, and its frame in the paper's
/// scroll content is where the story is on screen. A SwiftUI preference was
/// used first and went stale: when the masonry reshuffled its columns twice in
/// one update, 16 ms apart, the second set of frames was never delivered, and
/// every arrow after it steered by the first, into the wrong column.
@MainActor
final class KeyNavAnchors {
    static let shared = KeyNavAnchors()

    /// Called once the set of stories has changed, after the change settles.
    var changed: (() -> Void)?

    private final class Weak { weak var view: NSView?; init(_ view: NSView) { self.view = view } }
    /// Every view a story has, newest last. A story reshuffled into another
    /// column gets a new view, and for a moment it can have both: they join
    /// and leave in no fixed order, so each view is removed only by its own
    /// leaving, and the story is gone only when all of its views are.
    private var views: [String: [Weak]] = [:]
    private var notifyPending = false

    func register(_ id: String, _ view: NSView) {
        var list = (views[id] ?? []).filter { $0.view != nil && $0.view !== view }
        list.append(Weak(view))
        views[id] = list
        notify()
    }

    func unregister(_ id: String, _ view: NSView) {
        guard let list = views[id], list.contains(where: { $0.view === view }) else { return }
        let rest = list.filter { $0.view != nil && $0.view !== view }
        views[id] = rest.isEmpty ? nil : rest
        notify()
    }

    /// Every story's frame, in the paper's content: top-down, as the scroll
    /// offset is measured.
    func frames() -> [String: CGRect] {
        guard let document = KeyboardScroller.shared.paperDocument else { return [:] }
        var result: [String: CGRect] = [:]
        for (id, list) in views {
            guard let view = list.last(where: { $0.view?.window === document.window })?.view else { continue }
            var rect = view.convert(view.bounds, to: document)
            if !document.isFlipped { rect.origin.y = document.bounds.height - rect.maxY }
            result[id] = rect
        }
        return result
    }

    /// One call per run of changes, not one per story.
    private func notify() {
        guard !notifyPending else { return }
        notifyPending = true
        DispatchQueue.main.async { [weak self] in
            self?.notifyPending = false
            self?.changed?()
        }
    }
}

/// Registers a story with KeyNav and draws the highlight when it is the
/// highlighted one.
///
/// The highlight is an outline drawn outside the card with clearance, and
/// nothing is laid over the card or behind it, so pictures, including ones with
/// transparency, are left exactly as they are. It never changes layout, so the
/// masonry estimate is unaffected.
extension View {
    func keyNavTarget(for item: FeedItem) -> some View {
        modifier(KeyNavTarget(item: item))
    }
}

private struct KeyNavTarget: ViewModifier {
    @Environment(AppStore.self) private var store
    let item: FeedItem

    private var highlighted: Bool {
        store.keyNavActive && store.keyNavItemId == item.itemId
    }

    func body(content: Content) -> some View {
        content
            .background(KeyNavAnchor(id: item.itemId))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 2)
                        .padding(-8)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The invisible view that stands for one story in `KeyNavAnchors`. It takes
/// the story's size and position and nothing else: it draws nothing and lets
/// every click and hover through to the story.
private struct KeyNavAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.id = id
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.id = id
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.id = nil
    }

    final class AnchorView: NSView {
        var id: String? {
            didSet {
                guard id != oldValue else { return }
                if let oldValue { KeyNavAnchors.shared.unregister(oldValue, self) }
                attach()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func attach() {
            guard let id else { return }
            if window == nil {
                KeyNavAnchors.shared.unregister(id, self)
            } else {
                KeyNavAnchors.shared.register(id, self)
            }
        }
    }
}

/// Drives KeyNav from the keyboard. One per paper; hands its key handler to
/// `KeyboardScroller`, which only consults it while the paper is in front.
@MainActor
final class KeyNavController {
    weak var store: AppStore?
    /// Read afresh every time, never kept: see `KeyNavAnchors`.
    private var frames: [String: CGRect] { KeyNavAnchors.shared.frames() }
    /// Where the highlighted story was when it was last seen, so that if it
    /// disappears (read, with hide-read on) the one filling its slot takes over.
    private var lastRect: CGRect?

    /// The paper's own margins: 32 above the page, 72 below it when the page
    /// pill is showing, which is exactly the space the pill needs. A story kept
    /// in view is kept clear of both.
    var topMargin: CGFloat = 32
    var bottomMargin: CGFloat = 72

    func handle(_ event: NSEvent) -> Bool {
        guard let store else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 48:  // Tab
            if !store.keyNavActive {
                guard let first = KeyNav.first(in: frames) else { return false }
                store.keyNavActive = true
                highlight(first)
            }
            return true
        case 53:  // Esc
            guard store.keyNavActive else { return false }
            store.keyNavActive = false
            return true
        default:
            break
        }
        guard store.keyNavActive else { return false }
        switch event.keyCode {
        case 36, 76:  // Return, Enter
            guard let id = store.keyNavItemId, let item = item(id) else { return true }
            lastRect = frames[id]
            store.openArticle(item)
            return true
        case 126: move(.up); return true
        case 125: move(.down); return true
        case 123: move(.left); return true
        case 124: move(.right); return true
        default:
            return false
        }
    }

    /// The page has turned: start again from its first story.
    func pageTurned() {
        store?.keyNavItemId = nil
        lastRect = nil
    }

    /// A story was opened, by Return or by a click: that is where to come back to.
    func articleOpened(_ id: String) {
        guard store?.keyNavActive == true else { return }
        store?.keyNavItemId = id
        lastRect = frames[id]
    }

    private func move(_ direction: KeyNavDirection) {
        guard let store else { return }
        let frames = frames
        // If scrolling with space or Page Down has taken the highlight off the
        // screen, carry on from the first story in view rather than jumping back.
        if let id = store.keyNavItemId, let rect = frames[id],
           let visible = KeyboardScroller.shared.paperVisibleRect(),
           !rect.intersects(visible),
           let resume = KeyNav.firstVisible(in: frames, visible: visible) {
            highlight(resume)
            return
        }
        guard let id = store.keyNavItemId else {
            if let first = KeyNav.first(in: frames) { highlight(first) }
            return
        }
        if let next = KeyNav.next(from: id, direction, in: frames) { highlight(next) }
    }

    /// The page has been moved by Page Up, Page Down, space, Home or End: bring
    /// the highlight onto the screen, so the next arrow starts from what can be
    /// seen. The page has already landed when this runs, because those keys
    /// scroll at once rather than animating.
    func paperPaged() {
        guard let store, store.keyNavActive,
              let visible = KeyboardScroller.shared.paperVisibleRect() else { return }
        let frames = frames
        guard let id = KeyNav.afterPaging(from: store.keyNavItemId, in: frames, visible: visible) else { return }
        // Not revealed: the story is already on screen, and scrolling to show it
        // whole would take back part of the page the user has just turned.
        highlight(id, reveal: false)
    }

    private func highlight(_ id: String, reveal: Bool = true) {
        store?.keyNavItemId = id
        // The address strip follows the highlight, the way it follows the
        // pointer: in KeyNav the highlight is where you are pointing.
        store?.keyNavLink = item(id)?.link
        store?.linkFromKeyboard = true
        guard let rect = frames[id] else { return }
        lastRect = rect
        if reveal { KeyboardScroller.shared.revealInPaper(rect, top: topMargin, bottom: bottomMargin) }
    }

    /// Keeps the highlight on a real story as the page changes under it.
    func storiesChanged() {
        let frames = frames
        guard let store, store.keyNavActive, !frames.isEmpty else { return }
        if let id = store.keyNavItemId, let rect = frames[id] {
            lastRect = rect
            return
        }
        // Gone (read, with hide-read on) or never set (a new page).
        let replacement = lastRect.flatMap { KeyNav.nearest(to: $0, in: frames) } ?? KeyNav.first(in: frames)
        if let replacement { highlight(replacement) }
    }

    private func item(_ id: String) -> FeedItem? {
        guard let store, let edition = store.visibleEdition ?? store.editionStore.today else { return nil }
        let all = [edition.lead].compactMap { $0 } + edition.secondaries + edition.briefs
            + edition.sections.flatMap(\.items)
        return all.first { $0.itemId == id }
    }
}
