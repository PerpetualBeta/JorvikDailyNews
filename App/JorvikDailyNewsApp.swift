import SwiftUI
import Sparkle

@main
struct JorvikDailyNewsApp: App {
    /// Assigned in `init()` rather than given a default value here.
    ///
    /// Swift assigns default property values BEFORE the body of `init()`
    /// runs, and `AppStore`'s own properties load `feeds.json`, `read.json`
    /// and `classifier.json` in their initialisers. A default here would
    /// therefore read an empty sandbox container before `StoreMigration`
    /// could put anything in it, and the first launch after sandboxing would
    /// look — accurately — like every subscription had vanished.
    @State private var store: AppStore
    private let sparkleUpdater: SPUStandardUpdaterController
    private let sparkleUserDriverDelegate = JorvikDailyNewsUserDriverDelegate()

    init() {
        // BEFORE anything reads a store. See the note on `store` above: the
        // sandbox moved the app's data into a container, and this copies the
        // pre-sandbox store across once so nobody loses their subscriptions.
        StoreMigration.runIfNeeded()
        _store = State(wrappedValue: AppStore())

        // First line of the run, so anyone who has just switched diagnostics on
        // can see that it took effect — and so a log pasted into an issue
        // carries the app and OS versions even if the reader is never opened.
        jdnLog("launch")
        // Which mode produced this log. Without it a pictures-off run reads
        // identically to a run where no picture happened to load.
        jdnLog(ImageCache.configSummary)
        jdnLog(ArticleExtractor.configSummary)

        // Tugboat-cooperative dock visibility. Listens for hide/show
        // toggles broadcast by Tugboat and self-applies via setActivationPolicy.
        JorvikDockVisibility.adopt()

        // Sparkle handles update checking/installation. Started immediately so
        // the once-a-day background check honours the schedule in Info.plist.
        sparkleUpdater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: sparkleUserDriverDelegate
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 700)
        }
        .defaultSize(width: 1100, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Jorvik Daily News") {
                    JorvikAboutView.showWindow(
                        appName: "Jorvik Daily News",
                        repoName: "JorvikDailyNews",
                        productPage: "apps/jorvik-daily-news"
                    )
                }
                Button("Check for Updates\u{2026}") {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    sparkleUpdater.checkForUpdates(nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Feed\u{2026}") {
                    store.showAddFeedSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Edition") {
                Button("Back to Paper") {
                    store.selectedArticle = nil
                }
                .keyboardShortcut(.delete)
                .disabled(store.selectedArticle == nil)

                Divider()

                Button("Refresh Feeds") {
                    Task { await store.refreshAndPublish() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.feedStore.feeds.isEmpty || store.isRefreshing)

                Divider()

                Button("Manage Feeds\u{2026}") {
                    store.showManageFeedsSheet = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Import OPML\u{2026}") {
                    store.showOPMLImporter = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(store.isImporting)

                Button("Export OPML\u{2026}") {
                    store.showOPMLExporter = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.feedStore.feeds.isEmpty)

                Divider()

                Button("Front Page") {
                    store.goToFrontPage()
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(store.editionStore.today == nil)

                Button("Previous Page") {
                    store.previousPage()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(store.pageIndex == 0)

                Button("Next Page") {
                    store.nextPage()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(store.pageIndex >= store.totalPages - 1)
            }
        }
    }
}

/// Keeps Sparkle's update UI visible across the whole session, including
/// when the user switches to another app mid-download. See KB:
/// `conventions/sparkle-integration.md` §6 for the rationale.
final class JorvikDailyNewsUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}
