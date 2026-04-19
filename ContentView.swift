import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppStore.self) private var store

    // Accept .opml (common OPML extension) plus any XML. If the system
    // doesn't recognise .opml as a UTType, fall back to XML only.
    private static let opmlTypes: [UTType] = {
        if let opml = UTType(filenameExtension: "opml") {
            return [opml, .xml]
        }
        return [.xml]
    }()

    private static let opmlWriteType: UTType = {
        UTType(filenameExtension: "opml") ?? .xml
    }()

    private static var exportFilename: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "JorvikDailyNews-subscriptions-\(f.string(from: Date()))"
    }

    var body: some View {
        @Bindable var bindable = store
        content
            .background(Color(nsColor: .textBackgroundColor))
            .task { await store.onLaunch() }
            .sheet(isPresented: $bindable.showAddFeedSheet) {
                AddFeedSheet()
                    .environment(store)
            }
            .sheet(isPresented: $bindable.showManageFeedsSheet) {
                ManageFeedsSheet()
                    .environment(store)
            }
            .fileImporter(
                isPresented: $bindable.showOPMLImporter,
                allowedContentTypes: Self.opmlTypes,
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                // Permission: fileImporter returns a security-scoped URL; start
                // accessing before reading, stop after.
                let didAccess = url.startAccessingSecurityScopedResource()
                Task {
                    await store.importOPML(from: url)
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
            }
            .fileExporter(
                isPresented: $bindable.showOPMLExporter,
                document: OPMLDocument(text: OPMLExporter.export(feeds: store.feedStore.feeds)),
                contentType: Self.opmlWriteType,
                defaultFilename: Self.exportFilename
            ) { _ in }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        bindable.showAddFeedSheet = true
                    } label: {
                        Label("Add Feed", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        bindable.showManageFeedsSheet = true
                    } label: {
                        Label("Manage Feeds", systemImage: "list.bullet")
                    }
                    .disabled(store.feedStore.feeds.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.refreshAndPublish() }
                    } label: {
                        if store.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(store.feedStore.feeds.isEmpty || store.isRefreshing)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let article = store.selectedArticle {
            ReaderView(item: article)
                .environment(store)
                .transition(.opacity)
        } else if store.feedStore.feeds.isEmpty {
            EmptyStateView()
        } else if let edition = store.editionStore.today, !edition.isEmpty {
            ZStack(alignment: .bottom) {
                ScrollView {
                    currentPage(for: edition)
                        .padding(.horizontal, 48)
                        .padding(.top, 32)
                        // Extra bottom padding clears the floating page
                        // indicator pill so trailing content (e.g. "N more
                        // in archive") isn't obscured.
                        .padding(.bottom, store.totalPages > 1 ? 72 : 32)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                        .id(store.pageIndex)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.18), value: store.pageIndex)

                if store.totalPages > 1 {
                    PageIndicator()
                        .environment(store)
                        .padding(.bottom, 12)
                }
            }
        } else if store.isRefreshing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Printing today\u{2019}s edition\u{2026}")
                    .font(.custom("Charter", size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 16) {
                Text("No news today")
                    .font(.custom("Didot", size: 36))
                if let err = store.lastRefreshError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                Button("Refresh") {
                    Task { await store.refreshAndPublish() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func currentPage(for edition: Edition) -> some View {
        if store.pageIndex == 0 {
            FrontPage(edition: edition)
        } else {
            let idx = store.pageIndex - 1
            if idx < edition.sections.count {
                SectionPageView(
                    page: edition.sections[idx],
                    date: edition.date,
                    pageNumber: store.pageIndex + 1,
                    totalPages: store.totalPages
                )
            } else {
                FrontPage(edition: edition)
            }
        }
    }
}

private struct PageIndicator: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            Button {
                store.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(store.pageIndex == 0)
            .help("Previous page (\u{2318}\u{2190})")

            Text(label)
                .font(.custom("Charter", size: 11))
                .kerning(1.5)
                .foregroundStyle(.primary)
                .monospacedDigit()

            Button {
                store.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(store.pageIndex >= store.totalPages - 1)
            .help("Next page (\u{2318}\u{2192})")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        )
    }

    private var label: String {
        "PAGE \(store.pageIndex + 1) OF \(store.totalPages) \u{00B7} \(store.currentPageTitle.uppercased())"
    }
}

struct EmptyStateView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var bindable = store
        VStack(spacing: 16) {
            Text("Jorvik Daily News")
                .font(.custom("Didot", size: 48))
                .kerning(1)
            Text("A daily newspaper printed from your RSS feeds.")
                .font(.custom("Charter", size: 16))
                .foregroundStyle(.secondary)
            Text("Add a feed to publish today\u{2019}s edition.")
                .font(.custom("Charter", size: 14))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            Button("Add Feed\u{2026}") {
                bindable.showAddFeedSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }
}
