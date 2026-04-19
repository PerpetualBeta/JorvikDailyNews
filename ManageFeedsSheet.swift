import SwiftUI

struct ManageFeedsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pendingRemoval: Feed?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Feeds")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    store.showOPMLImporter = true
                } label: {
                    Label("Import OPML\u{2026}", systemImage: "square.and.arrow.down")
                }
                .help("Bulk-add feeds from an OPML file")
                .disabled(store.isImporting)
                Button {
                    store.showOPMLExporter = true
                } label: {
                    Label("Export OPML\u{2026}", systemImage: "square.and.arrow.up")
                }
                .help("Export your feed list as OPML")
                .disabled(store.feedStore.feeds.isEmpty)
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            if let summary = store.lastImportSummary {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(summary)
                        .font(.caption)
                    Spacer()
                    Button {
                        store.lastImportSummary = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 8)
            }

            if store.feedStore.feeds.isEmpty {
                VStack(spacing: 8) {
                    Text("No feeds yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search feeds by title, URL, or section", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 6)

                ScrollView {
                    if filteredSections.isEmpty {
                        Text("No feeds match \u{201C}\(searchText)\u{201D}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(filteredSections, id: \.0) { section, feeds in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(section.uppercased())
                                        .font(.caption)
                                        .kerning(1.5)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 12)
                                    Divider()
                                    ForEach(feeds) { feed in
                                        FeedRow(
                                            feed: feed,
                                            onRemove: { pendingRemoval = feed },
                                            onTogglePause: {
                                                Task { await store.togglePause(feed) }
                                            }
                                        )
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 520)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { searchFocused = true }
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.title ?? $0.url.host ?? $0.url.absoluteString)?" } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { feed in
            Button("Remove", role: .destructive) {
                Task {
                    await store.removeFeed(feed)
                    pendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("Its stories will disappear from today\u{2019}s edition on the next refresh.")
        }
    }

    private var filteredFeeds: [Feed] {
        let term = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return store.feedStore.feeds }
        return store.feedStore.feeds.filter { feed in
            if (feed.title ?? "").lowercased().contains(term) { return true }
            if feed.url.absoluteString.lowercased().contains(term) { return true }
            if feed.section.lowercased().contains(term) { return true }
            return false
        }
    }

    private var filteredSections: [(String, [Feed])] {
        let grouped = Dictionary(grouping: filteredFeeds) { $0.section }
        return grouped
            .map { ($0.key, $0.value.sorted { ($0.title ?? "") < ($1.title ?? "") }) }
            .sorted { $0.0.lowercased() < $1.0.lowercased() }
    }

    private var countLabel: String {
        let total = store.feedStore.feeds.count
        let shown = filteredFeeds.count
        if shown == total {
            return "\(total) feed\(total == 1 ? "" : "s")"
        } else {
            return "\(shown) of \(total)"
        }
    }
}

private struct FeedRow: View {
    let feed: Feed
    let onRemove: () -> Void
    let onTogglePause: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feed.title ?? feed.url.host ?? feed.url.absoluteString)
                        .font(.body)
                    if feed.isPaused {
                        Text("PAUSED")
                            .font(.caption2)
                            .kerning(1.2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(feed.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onTogglePause) {
                Image(systemName: feed.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(feed.isPaused ? "Resume feed" : "Pause feed")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove feed")
        }
        .padding(.vertical, 8)
        .opacity(feed.isPaused ? 0.55 : 1.0)
    }
}
