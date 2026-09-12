import SwiftUI

/// One line under the dateline when a feed has quietly stopped working.
///
/// **A feed that fails for ever looks exactly like a feed with nothing new.**
/// Nine plain-http feeds failed on every hourly refresh for a day after an
/// Info.plist change, and nothing in the paper said so: the manage-feeds sheet
/// had shown them as red dots the whole time, which helps nobody who has no
/// reason to open it, and the log line was one per feed per attempt behind a
/// flag that is off by default.
///
/// Deliberately not a badge and not a count that grows. This app has no unread
/// counts and no nagging by design, so this is a printer's note: it states a
/// fact when the fact is true, and it is not there the rest of the time.
/// A publisher being down overnight is not an announcement — `Feed`'s
/// threshold is a day.
struct SilentFeedNotice: View {
    let feeds: [Feed]
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
            Text(feeds.silentFailureSentence)
                .font(.custom("Charter", size: 11))
                .italic()
            // Underlined rather than coloured. A blue link would be the only
            // colour on a black-and-white page, and something that looks like
            // running text and is clickable is the fault this project has
            // already fixed once in the reader.
            Button(action: onReview) {
                Text(feeds.silentFailureAction)
                    .font(.custom("Charter", size: 11))
                    .underline()
            }
            .buttonStyle(.link)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 6)
        // Announced once, as a single sentence, rather than as three controls.
        .accessibilityElement(children: .combine)
    }
}
