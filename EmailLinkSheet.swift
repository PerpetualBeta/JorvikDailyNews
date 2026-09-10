import AppKit
import SwiftUI

/// Shown when an article link wants to send an email.
///
/// The reader clicked a headline, not a compose window, and `mailto:` is the
/// one link type in an article that can carry instructions the reader cannot
/// see. So the address is shown before Mail is involved, and anything the
/// sheet is not showing has already been dropped by `MailtoLink` rather than
/// forwarded quietly.
struct EmailLinkSheet: View {
    let mail: MailtoLink
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("This link sends an email")
                .font(.custom("Didot", size: 22))
                .padding(.bottom, 14)

            LabelledRow(label: "To", value: mail.recipients)
            if let subject = mail.subject, !subject.isEmpty {
                LabelledRow(label: "Subject", value: subject)
            }

            if !mail.discarded.isEmpty {
                // Named rather than hinted at. A `bcc` field is the reason
                // this sheet exists, and "some fields were removed" would tell
                // the reader nothing about which.
                Text(dropped)
                    .font(.custom("Charter", size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Text("Nothing is sent. Your mail app opens with a new message, "
                 + "which you can read and change before sending.")
                .font(.custom("Charter", size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Open in Mail") {
                    if let url = mail.safeURL {
                        jdnLog("reader: opening a new message to \(mail.recipients)")
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(26)
        .frame(width: 420)
    }

    /// "The link also set a bcc address and a message body. Both were removed."
    private var dropped: String {
        let names = mail.discarded.map { field -> String in
            switch field {
            case "bcc": return "a hidden bcc address"
            case "cc": return "a cc address"
            case "body": return "a prefilled message body"
            default: return "a \(field) field"
            }
        }
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = names[0] + " and " + names[1]
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "The link also set \(list). "
             + (names.count == 1 ? "It has been removed." : "They have been removed.")
    }
}

/// One field of the sheet, label above value, the value selectable so the
/// reader can copy an address rather than retype it.
private struct LabelledRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.custom("Charter", size: 9))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.custom("Charter", size: 14))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
    }
}
