import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The page's own geometry. Named because three separate things need to agree
/// on it: the frame that draws the page, the standfirst planner that decides
/// how many columns the measure warrants, and the width a view assumes on its
/// first frame before it has been measured.
enum Paper {
    /// The broadsheet never runs wider than this however wide the window is.
    /// Beyond it the measure stops being readable and the page stops looking
    /// like a page.
    static let maxWidth: CGFloat = 1100

    /// Margin either side of the printed area.
    static let horizontalPadding: CGFloat = 48

    /// What the content itself gets. The window minimum is 900 wide, so in
    /// practice this runs 804–1004pt.
    static let maxContentWidth: CGFloat = maxWidth - horizontalPadding * 2
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var scrollFocused: Bool

    // Accept .opml (common OPML extension) plus any XML. If the system
    // doesn't recognise .opml as a UTType, fall back to XML only.
    static let opmlTypes: [UTType] = {
        if let opml = UTType(filenameExtension: "opml") {
            return [opml, .xml]
        }
        return [.xml]
    }()

    static let opmlWriteType: UTType = {
        UTType(filenameExtension: "opml") ?? .xml
    }()

    static var exportFilename: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "JorvikDailyNews-subscriptions-\(f.string(from: Date()))"
    }

    var body: some View {
        @Bindable var bindable = store
        content
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) {
                if let notice = store.addFeedNotice {
                    AddFeedNoticeView(notice: notice) { store.addFeedNotice = nil }
                        .padding(.horizontal, Paper.horizontalPadding)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                        .task(id: notice.id) {
                            try? await Task.sleep(for: AddFeedNoticeView.lifetime(of: notice))
                            if store.addFeedNotice?.id == notice.id { store.addFeedNotice = nil }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: store.addFeedNotice)
            .background {
                BackspaceKeyMonitor {
                    guard store.selectedArticle != nil else { return false }
                    store.selectedArticle = nil
                    return true
                }
            }
            .background {
                // Back and Forward as a swipe event, which is how a remapper
                // such as MacSideButtons sends a mouse's side buttons. They do
                // what the keys already do.
                SwipeMonitor { direction in
                    if store.selectedArticle != nil {
                        guard direction == .back else { return false }
                        store.selectedArticle = nil
                        return true
                    }
                    switch direction {
                    case .back:
                        guard store.pageIndex > 0 else { return false }
                        store.previousPage()
                    case .forward:
                        guard store.pageIndex < store.totalPages - 1 else { return false }
                        store.nextPage()
                    }
                    return true
                }
            }
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
                    Toggle(isOn: $bindable.hideReadItems) {
                        Label("Unread only", systemImage: "eye.slash")
                    }
                    .toggleStyle(.switch)
                    .help("Hide items you\u{2019}ve already read")
                }
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
        if store.feedStore.feeds.isEmpty {
            EmptyStateView()
        } else if let edition = store.visibleEdition ?? store.editionStore.today, !edition.isEmpty {
            // The reader lays *over* the still-mounted paper rather than
            // replacing it, so the paper's NSScrollView keeps its scroll
            // offset. Back to Paper then returns you to the exact spot you
            // left from, not the top of the page.
            paper(for: edition)
                .overlay {
                    if let article = store.selectedArticle {
                        ReaderView(item: article)
                            .environment(store)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    }
                }
        } else if let article = store.selectedArticle {
            // Edge case: hide-read emptied the edition out from under us while
            // an article was open. Keep the reader rather than dumping the
            // user back to an empty paper.
            ReaderView(item: article)
                .environment(store)
                .transition(.opacity)
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

    /// Height of the visible page, which is the scroll view's own frame rather
    /// than its content. The lead picture is capped as a share of it, so a tall
    /// window shows more of a photograph instead of letterboxing it.
    @State private var pageHeight: CGFloat = 0

    @ViewBuilder
    private func paper(for edition: Edition) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Invisible anchors at top + bottom — Home / End and
                    // page-turn transitions scrollTo these ids.
                    Color.clear.frame(height: 0.1).id("top")
                    currentPage(for: edition)
                        .padding(.horizontal, Paper.horizontalPadding)
                        .padding(.top, 32)
                        .padding(.bottom, store.totalPages > 1 ? 72 : 32)
                        .frame(maxWidth: Paper.maxWidth)
                        .frame(maxWidth: .infinity)
                        .id(store.pageIndex)
                        .transition(.opacity)
                    Color.clear.frame(height: 0.1).id("bottom")
                }
            }
            // A background never affects layout, so this reads the viewport
            // without being able to feed back into it.
            .background(
                GeometryReader { viewport in
                    Color.clear.onChange(of: viewport.size.height, initial: true) { _, new in
                        if new > 0 { pageHeight = new }
                    }
                }
            )
            // Let the scroll view accept key presses. Home/End scroll to
            // anchors; PgUp/PgDn/space fall through to the underlying
            // NSScrollView which handles them natively once focused.
            .focusable()
            .focusEffectDisabled()
            .focused($scrollFocused)
            // Hold key focus only while the paper is the front-most view. With
            // the reader open over the top, the paper must not catch Home / End
            // / PgUp / PgDn and scroll itself behind the article.
            .onAppear { scrollFocused = store.selectedArticle == nil }
            .onChange(of: store.selectedArticle == nil) { _, paperIsFront in
                scrollFocused = paperIsFront
            }
            .onKeyPress(.home) {
                guard store.selectedArticle == nil else { return .ignored }
                proxy.scrollTo("top", anchor: .top)
                return .handled
            }
            .onKeyPress(.end) {
                guard store.selectedArticle == nil else { return .ignored }
                proxy.scrollTo("bottom", anchor: .bottom)
                return .handled
            }
            .animation(.easeInOut(duration: 0.18), value: store.pageIndex)
            .onChange(of: store.pageIndex) { _, _ in
                proxy.scrollTo("top", anchor: .top)
            }
            // Floating page-indicator as an overlay on the ScrollView's
            // frame. Overlay alignment is relative to the viewport, so
            // the pill is always bottom-centred regardless of the
            // scroll content's settled size.
            .overlay(alignment: .bottom) {
                // Three columns: the hovered link on the left, the page pill,
                // and an empty column the same width as the first. The two
                // outer columns share the leftover space equally, so the pill
                // stays centred and a long address truncates inside its own
                // half instead of running underneath the pill.
                HStack(alignment: .bottom, spacing: 12) {
                    // The column must exist even when nothing is hovered.
                    // With no link the strip draws nothing, SwiftUI drops an
                    // empty view from the row, and the empty column on the
                    // right then takes all the spare width and shoves the pill
                    // left. The zero-height clear view keeps this column in
                    // the row, so the two outer columns always balance.
                    ZStack(alignment: .bottomLeading) {
                        Color.clear.frame(maxHeight: 0)
                        LinkStatusStrip()
                            .environment(store)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if store.totalPages > 1 {
                        // Its natural width, always. Without this the row
                        // squeezes the pill to make room for a long address,
                        // and at the minimum window width the longest page
                        // title is cut off. The address is what gives way.
                        PageIndicator()
                            .environment(store)
                            .fixedSize()
                    }
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func currentPage(for edition: Edition) -> some View {
        if store.pageIndex == 0 {
            FrontPage(edition: edition, pageHeight: pageHeight)
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
                FrontPage(edition: edition, pageHeight: pageHeight)
            }
        }
    }
}

private struct BackspaceKeyMonitor: NSViewRepresentable {
    let action: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var action: () -> Bool
        private var monitor: Any?

        init(action: @escaping () -> Bool) {
            self.action = action
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 51,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      self?.action() == true else {
                    return event
                }
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

/// Hands a horizontal swipe to `action` as Back or Forward. Only swipes over
/// this view's own window count, and not while a sheet covers it, so a swipe
/// over Settings or Add Feed never turns a page behind it.
private struct SwipeMonitor: NSViewRepresentable {
    enum Direction { case back, forward }

    let action: (Direction) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var action: (Direction) -> Bool
        weak var view: NSView?
        private var monitor: Any?

        init(action: @escaping (Direction) -> Bool) {
            self.action = action
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
                guard let self,
                      let window = self.view?.window,
                      event.window === window,
                      window.attachedSheet == nil else {
                    return event
                }
                // A swipe arrives as a pair. The first carries no direction,
                // and acting on it as well would turn two pages.
                let direction: Direction
                if event.deltaX > 0 {
                    direction = .back
                } else if event.deltaX < 0 {
                    direction = .forward
                } else {
                    return event
                }
                return self.action(direction) ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

/// Where the article under the pointer comes from, shown bottom-left the way a
/// browser shows a hovered link.
///
/// A click opens the article in JDN's own reader rather than a browser, so this
/// is the article's source rather than somewhere the click will take you, and
/// the wording on screen is just the address for that reason.
///
/// Shown as host and path. The scheme and a leading `www.` say nothing a reader
/// needs. The query is dropped because in a feed it is almost always tracking
/// (`utm_source` and friends), and with middle truncation a long query would
/// survive at the expense of the path, which is the part that says what the
/// article is.
///
/// Stands aside while the add-feed notice is up, which uses the same edge.
private struct LinkStatusStrip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let link = store.hoveredLink, store.addFeedNotice == nil {
            Text(Self.display(link))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1))
                )
                .allowsHitTesting(false)
                .help(link.absoluteString)
        }
    }

    static func display(_ url: URL) -> String {
        guard var host = url.host() else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path()
        if path == "/" { path = "" }
        if path.hasSuffix("/") { path.removeLast() }
        return host + path
    }
}

private struct PageIndicator: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.previousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.pageIndex == 0)
            .help("Previous page (\u{2318}\u{2190})")

            // Every page's label stacked in one place, all but the current one
            // hidden. A ZStack is as wide as its widest member, so the pill is
            // sized for the longest label in the paper and the buttons either
            // side stay put from page to page instead of following the title.
            // Built from the real page titles, so adding or renaming a section
            // re-sizes it with no width to tune. It also absorbs the page number
            // gaining a digit, which fixed-width figures alone do not.
            ZStack {
                ForEach(Array(store.allPageTitles.enumerated()), id: \.offset) { index, _ in
                    labelText(for: index)
                        .opacity(index == store.pageIndex ? 1 : 0)
                        .accessibilityHidden(index != store.pageIndex)
                }
            }
            .padding(.horizontal, 8)

            Button {
                store.nextPage()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.pageIndex >= store.totalPages - 1)
            .help("Next page (\u{2318}\u{2192})")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        )
    }

    private func labelText(for index: Int) -> some View {
        Text("PAGE \(index + 1) OF \(store.totalPages) \u{00B7} \(store.pageTitle(at: index).uppercased())")
            .font(.custom("Charter", size: 11))
            .kerning(1.5)
            .foregroundStyle(.primary)
            .monospacedDigit()
            .lineLimit(1)
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
