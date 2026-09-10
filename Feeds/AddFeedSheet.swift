import SwiftUI

struct AddFeedSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var section = "News"
    @State private var isAdding = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private let suggestedSections = ["News", "Tech", "Culture", "Opinion", "Business", "Sport"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Feed")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 6) {
                Text("Feed or site URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://example.com", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .autocorrectionDisabled(true)
                Text("Paste a feed URL, or a site\u{2019}s home page \u{2014} we\u{2019}ll find the feed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Section")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Section name", text: $section)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                HStack(spacing: 6) {
                    ForEach(suggestedSections, id: \.self) { s in
                        Button(s) { section = s }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            if let statusMessage {
                HStack(spacing: 8) {
                    if isAdding { ProgressView().controlSize(.small) }
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAdding)
                Button(buttonLabel) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAdding || !canSubmit)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var canSubmit: Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespaces)
        let trimmedSection = section.trimmingCharacters(in: .whitespaces)
        return !trimmedURL.isEmpty && !trimmedSection.isEmpty
    }

    private var buttonLabel: String {
        isAdding ? "Finding feed\u{2026}" : "Add Feed"
    }

    private func submit() {
        let raw = urlString.trimmingCharacters(in: .whitespaces)
        let normalised = raw.hasPrefix("http") ? raw : "https://" + raw
        guard let url = URL(string: normalised),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil else {
            errorMessage = "Enter a valid URL"
            return
        }
        isAdding = true
        errorMessage = nil
        statusMessage = "Looking for a feed at \(url.host ?? url.absoluteString)\u{2026}"
        Task {
            do {
                let added = try await store.discoverAndAdd(url: url, section: section)
                statusMessage = "Added \(added.title ?? added.url.host ?? added.url.absoluteString)"
                isAdding = false
                try? await Task.sleep(nanoseconds: 500_000_000)
                dismiss()
            } catch {
                isAdding = false
                statusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
