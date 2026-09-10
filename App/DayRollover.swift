import Foundation

/// Decides whether a refresh is the first one of a new day.
///
/// Separate from the refresh itself because getting it wrong is silent. On the
/// night of 9 September 2026 the reset ran **twice**, at 00:00:43 and again at
/// 01:00:36, under a comment that said it "reaches here once".
///
/// The reason it repeated is worth keeping. Just after midnight nothing has
/// been published yet, so the rebuild is legitimately empty, and the guard
/// that stops an empty rebuild wiping the paper returns early *without saving
/// a new edition*. The stored edition therefore still carries yesterday's
/// date an hour later, the "is this a new day" test looks at that date, and it
/// is still true. It stays true until something is finally published.
///
/// A quiet night makes it worse, not better: with nothing publishing until
/// 06:00 the reset would run six times, and each run throws away every picture
/// decoded since the last one. Anybody reading the held-over paper at half
/// past the hour loses their pictures on the hour, every hour.
///
/// So the question is not "does the stored edition look old" — that stays true
/// for as long as the paper is held — but "have we already done this today".
enum DayRollover {

    /// Whether the day-scoped state should be cleared now.
    ///
    /// - Parameters:
    ///   - editionDate: the date of the edition currently in the store.
    ///   - lastReset: when a reset last ran, or nil if not yet this launch.
    ///   - now: the current time.
    static func isDue(editionDate: Date, lastReset: Date?, now: Date) -> Bool {
        let calendar = Calendar.current
        // The stored edition is today's, so nothing has rolled over.
        guard !calendar.isDate(editionDate, inSameDayAs: now) else { return false }
        // Already done for this calendar day.
        if let lastReset, calendar.isDate(lastReset, inSameDayAs: now) { return false }
        return true
    }
}
