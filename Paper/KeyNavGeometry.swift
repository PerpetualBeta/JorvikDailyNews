import CoreGraphics

// The geometry behind KeyNav: which story an arrow, or a turned page, lands on.
// Pure functions of the stories' frames, with no AppKit or SwiftUI, so the test
// build can compile this file and check the rules directly.

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
    /// The first story in reading order: topmost, then leftmost.
    static func first(in frames: [String: CGRect]) -> String? {
        frames.min { readingOrder($0.value, $1.value) }?.key
    }

    /// The first story at least partly inside `visible`, in reading order.
    static func firstVisible(in frames: [String: CGRect], visible: CGRect) -> String? {
        frames.filter { $0.value.intersects(visible) }.min { readingOrder($0.value, $1.value) }?.key
    }

    /// Where the highlight belongs after the page has moved under it, by Page
    /// Up, Page Down, space, Home or End. Nil means leave it where it is.
    ///
    /// Jonathan's rule (2026-10-02): after paging, the next choice is made
    /// from what is on screen, so the highlight must be on screen too. It stays
    /// put if its story is still wholly in view. Otherwise it goes to the first
    /// story whose top is in view, in reading order, which is where the eye
    /// lands on a fresh page. A story cut off at the top is passed over: picking
    /// it would mean either highlighting something mostly gone or scrolling
    /// back up to show it, which would undo the page. Only when no story starts
    /// in view, one tall story filling the screen, does the partly visible one win.
    static func afterPaging(from id: String?, in frames: [String: CGRect], visible: CGRect) -> String? {
        if let id, let rect = frames[id], visible.contains(rect) { return nil }
        let starting = frames.filter { $0.value.minY >= visible.minY && $0.value.minY < visible.maxY }
        if let first = starting.min(by: { readingOrder($0.value, $1.value) })?.key { return first }
        return firstVisible(in: frames, visible: visible)
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
