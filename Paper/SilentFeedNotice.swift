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
///
/// Two feeds can be silent for opposite reasons, and the note says which.
/// `unreachable` is a feed that cannot be fetched at all. `dormant` is a feed
/// that fetches perfectly and has published nothing for over a year, which no
/// health signal in this app could see, because every one of them was about
/// the fetch rather than about the contents.
struct SilentFeedNotice: View {
    enum Kind {
        case unreachable
        case dormant
    }

    var kind: Kind = .unreachable
    let feeds: [Feed]
    let onReview: () -> Void

    private var sentence: String {
        switch kind {
        case .unreachable: feeds.silentFailureSentence
        case .dormant: feeds.dormantSentence
        }
    }

    /// A fault gets the warning glyph. Dormancy is not a fault — the feed is
    /// working exactly as it should and its author has stopped writing — so it
    /// gets a clock instead.
    private var glyph: String {
        switch kind {
        case .unreachable: "exclamationmark.circle"
        case .dormant: "clock"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 10))
            Text(sentence)
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
