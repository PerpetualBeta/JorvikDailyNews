import SwiftUI

@main
struct JorvikDailyNewsApp: App {
    @State private var store = AppStore()

    init() {
        // Tugboat-cooperative dock visibility. Listens for hide/show
        // toggles broadcast by Tugboat and self-applies via setActivationPolicy.
        JorvikDockVisibility.adopt()
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
                    Task { await store.updateChecker.checkNow() }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Feed\u{2026}") {
                    store.showAddFeedSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Edition") {
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
