import SwiftUI

/// One line at the foot of the window saying what the feed just added did.
///
/// The Add Feed sheet closes as soon as the feed is found, and the first fetch
/// happens after it has gone. This is where that fetch reports back. It is a
/// printer's note in the manner of `SilentFeedNotice`: the page's own type,
/// secondary ink, no colour, and gone again once it has been read.
struct AddFeedNoticeView: View {
    let notice: AppStore.AddFeedNotice
    let onDismiss: () -> Void

    /// Long enough to read a sentence once. A failure stays twice as long,
    /// because it names a reason and asks the reader to decide something.
    static func lifetime(of notice: AppStore.AddFeedNotice) -> Duration {
        notice.failed ? .seconds(12) : .seconds(6)
    }

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 8) {
                Image(systemName: notice.failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12))
                Text(notice.text)
                    .font(.custom("Charter", size: 13))
                    .italic()
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityElement(children: .combine)
        .onAppear {
            jdnLog("add feed: notice drawn")
            AccessibilityNotification.Announcement(notice.text).post()
        }
    }
}
