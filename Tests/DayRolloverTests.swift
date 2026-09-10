import Foundation

/// Written from a log, not from an idea.
///
/// On the night of 9 September 2026 the reset ran at 00:00:43 and again at
/// 01:00:36, under a comment claiming it happened once. These cases are that
/// night, replayed.
enum DayRolloverTests {

    static func run() {
        T.suite("Rollover: not due while the edition is today's") {
            let now = at("2026-09-10 14:00")
            T.expect(!DayRollover.isDue(editionDate: at("2026-09-10 09:00"),
                                        lastReset: nil, now: now),
                     "same day, nothing to reset")
        }

        T.suite("Rollover: due on the first refresh after midnight") {
            T.expect(DayRollover.isDue(editionDate: at("2026-09-09 22:00"),
                                       lastReset: nil, now: at("2026-09-10 00:00")),
                     "yesterday's edition, no reset yet")
        }

        T.suite("Rollover: not due a second time the same day") {
            // The bug. The 00:00 rebuild was empty, so the guard against
            // wiping the paper returned early WITHOUT saving, and the stored
            // edition still carried 9 September at 01:00. The old test — "does
            // the stored edition look old" — was still true, so the reset ran
            // again and threw away every picture decoded in between.
            let yesterday = at("2026-09-09 22:00")
            T.expect(!DayRollover.isDue(editionDate: yesterday,
                                        lastReset: at("2026-09-10 00:00"),
                                        now: at("2026-09-10 01:00")),
                     "already reset at midnight")
        }

        T.suite("Rollover: a quiet night does not reset once an hour") {
            // Nothing publishes until 06:00, so the stale edition is held for
            // six refreshes. Before the guard, that was six resets and six
            // emptied picture caches.
            let yesterday = at("2026-09-09 22:00")
            let firstReset = at("2026-09-10 00:00")
            var fired = 0
            var lastReset: Date? = nil
            for hour in 0...6 {
                let now = at(String(format: "2026-09-10 %02d:00", hour))
                if DayRollover.isDue(editionDate: yesterday, lastReset: lastReset, now: now) {
                    fired += 1
                    lastReset = now
                }
            }
            T.equal(fired, 1, "one reset across seven hourly refreshes")
            T.equal(lastReset, firstReset, "and it was the first one")
        }

        T.suite("Rollover: due again the NEXT day") {
            // The guard must not be so sticky that a machine left running for
            // days never resets again.
            T.expect(DayRollover.isDue(editionDate: at("2026-09-09 22:00"),
                                       lastReset: at("2026-09-10 00:00"),
                                       now: at("2026-09-11 00:00")),
                     "a new calendar day is due even though one reset already ran")
        }

        T.suite("Rollover: a reset later the same day still counts") {
            // Reset at 01:00 rather than at midnight, because the app was
            // asleep. A refresh at 02:00 must not repeat it.
            T.expect(!DayRollover.isDue(editionDate: at("2026-09-09 22:00"),
                                        lastReset: at("2026-09-10 01:00"),
                                        now: at("2026-09-10 02:00")),
                     "the reset time is what matters, not midnight")
        }
    }

    private static func at(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.calendar = Calendar.current
        f.timeZone = Calendar.current.timeZone
        guard let d = f.date(from: s) else { fatalError("unparseable: \(s)") }
        return d
    }
}
