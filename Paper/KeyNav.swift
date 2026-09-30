import AppKit
import SwiftUI

// KeyNav: moving a highlight through the paper's stories with the keyboard.
//
// Tab turns it on and highlights the first story on the page, the lead on the
// front page. The arrows move the highlight, Return opens the highlighted story
// exactly as a click would, and Esc turns it off. See `KeyNavController` for
// how it fits around the reader and the other keys.

/// Where every story on the current page sits, in the paper's scroll content.
struct KeyNavFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum KeyNavDirection { case up, down, left, right }

/// The navigation itself, as pure functions of the stories' frames, so it can
/// be tested on its own.
///
/// **Geometric, not a list.** The front page is a lead over a three-column
/// masonry grid whose columns do not line up row by row, so "the next item" has
/// no single meaning. An arrow instead moves to the nearest story in that
/// direction from where the highlighted one actually is: down and up stay in
/// the same column and step between the lead and the grid; left and right move
/// to the neighbouring column at about the same height.
enum KeyNav {
    static let space = "keyNavPaper"

    /// The first story in reading order: topmost, then leftmost.
    static func first(in frames: [String: CGRect]) -> String? {
        frames.min { readingOrder($0.value, $1.value) }?.key
    }

    /// The first story at least partly inside `visible`, in reading order.
    static func firstVisible(in frames: [String: CGRect], visible: CGRect) -> String? {
        frames.filter { $0.value.intersects(visible) }.min { readingOrder($0.value, $1.value) }?.key
    }

    /// The story whose top-left corner is closest to `rect`'s. Used when the
    /// highlighted story leaves the page, hidden once read: whichever story now
    /// fills its slot is the natural next one to read.
    static func nearest(to rect: CGRect, in frames: [String: CGRect]) -> String? {
        frames.min {
            hypot($0.value.minX - rect.minX, $0.value.minY - rect.minY)
                < hypot($1.value.minX - rect.minX, $1.value.minY - rect.minY)
        }?.key
    }

    static func next(from id: String, _ direction: KeyNavDirection,
                     in frames: [String: CGRect]) -> String? {
        guard let from = frames[id] else { return first(in: frames) }
        let ahead = frames.filter { $0.key != id && lies(from: from, to: $0.value, direction) }
        guard !ahead.isEmpty else { return nil }
        // Decided in order, never by weighing one distance against another. A
        // single weighted score was measured to skip a column: when the next
        // column had nothing level with the current story, the one beyond won.
        let vertical = direction == .up || direction == .down
        // 1. The nearest band across the direction of travel: for up and down,
        //    the same column if anything in it lies that way; for left and
        //    right, the adjacent column.
        let across: (CGRect) -> CGFloat = vertical
            ? { gap(from.minX, from.maxX, $0.minX, $0.maxX) }
            : { along(from, $0, direction) }
        let bandLimit = ahead.values.map(across).min()! + 1
        let band = ahead.filter { across($0.value) <= bandLimit }
        // 2. Within it, the closest: for up and down, the nearest in that
        //    direction; for left and right, the one beside the middle of the
        //    current story, so a sideways step stays level.
        let near: (CGRect) -> CGFloat = vertical
            ? { along(from, $0, direction) }
            : { beside(from.midY, $0) }
        let bestNear = band.values.map(near).min()! + 1
        // 3. A tie goes to reading order, so stepping down from the full-width
        //    lead lands on the left column, not the middle one.
        return band.filter { near($0.value) <= bestNear }
            .min { readingOrder($0.value, $1.value) }?.key
    }

    /// Whether `b` lies in `direction` from `a`. Up and down: it must START beyond `a`, not
    /// merely have its centre there: the tops of the three columns share one
    /// height, and a shorter card beside this one has its centre higher up, so
    /// a centre test called the next column's top card "above" and sent Up
    /// sideways instead of to the lead.
    private static func lies(from a: CGRect, to b: CGRect, _ d: KeyNavDirection) -> Bool {
        switch d {
        case .down:  return b.minY > a.minY + 1
        case .up:    return b.minY < a.minY - 1
        // Sideways, it must be clear of this story altogether. The full-width
        // lead starts left of every card and overlaps every column, so a
        // start-beyond test alone sent Left from the middle column up to it.
        case .right: return b.minX >= a.maxX - 1
        case .left:  return b.maxX <= a.minX + 1
        }
    }

    /// How far `b` is from `a` along the direction of travel, edge to edge.
    private static func along(_ a: CGRect, _ b: CGRect, _ d: KeyNavDirection) -> CGFloat {
        switch d {
        case .down:  return max(0, b.minY - a.maxY)
        case .up:    return max(0, a.minY - b.maxY)
        case .right: return max(0, b.minX - a.maxX)
        case .left:  return max(0, a.minX - b.maxX)
        }
    }

    /// How far a height `y` is from `b`'s vertical span, zero if inside it.
    private static func beside(_ y: CGFloat, _ b: CGRect) -> CGFloat {
        y < b.minY ? b.minY - y : (y > b.maxY ? y - b.maxY : 0)
    }

    /// The gap between two intervals on one axis, zero if they overlap.
    private static func gap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, max(a0, b0) - min(a1, b1))
    }

    private static func readingOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minY - b.minY) > 1 ? a.minY < b.minY : a.minX < b.minX
    }
}

/// Reports a story's frame to KeyNav and draws the highlight when it is the
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
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: KeyNavFramesKey.self,
                                           value: [item.itemId: geo.frame(in: .named(KeyNav.space))])
                }
            )
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

/// Drives KeyNav from the keyboard. One per paper; hands its key handler to
/// `KeyboardScroller`, which only consults it while the paper is in front.
@MainActor
final class KeyNavController {
    weak var store: AppStore?
    var frames: [String: CGRect] = [:] { didSet { framesChanged() } }
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

    private func highlight(_ id: String) {
        store?.keyNavItemId = id
        // The address strip follows the highlight, the way it follows the
        // pointer: in KeyNav the highlight is where you are pointing.
        store?.keyNavLink = item(id)?.link
        store?.linkFromKeyboard = true
        guard let rect = frames[id] else { return }
        lastRect = rect
        KeyboardScroller.shared.revealInPaper(rect, top: topMargin, bottom: bottomMargin)
    }

    /// Keeps the highlight on a real story as the page changes under it.
    private func framesChanged() {
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
