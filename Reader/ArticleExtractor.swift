import Foundation
import JavaScriptCore
import WebKit

/// Fetches an article URL via URLSession, then gets that HTML into something
/// Mozilla Readability can read.
///
/// URLSession handles the networking (so we can set headers, follow redirects,
/// and — critically — avoid the NSURLErrorCancelled that a hidden WKWebView
/// hits when it has no host window on macOS). Getting the fetched bytes into a
/// DOM is the part that has proved fragile, so it is no longer one call. It is
/// a ladder of five strategies, tried in order inside a single extraction, and
/// the log names the one that produced a document.
///
/// ## Why a ladder
///
/// On macOS 27.0 beta (26A5425a) `loadHTMLString` never produces a document.
/// The fetch is a clean 200, the HTML is handed over in full, and then the DOM
/// stays at the 39-character empty skeleton a web view starts with, for ever:
/// `estimatedProgress` parks at 0.10, `isLoading` stays true, no navigation
/// callback of any kind arrives, and `evaluateJavaScript` keeps answering, so
/// the renderer is alive and idle. Identical for 157 KB and 1.6 MB, identical
/// with the content rule list attached and detached, and identical across nine
/// releases. The same signed binary works perfectly on macOS 26.6.2.
///
/// Nine releases each shipped one theory and learned one bit, because a theory
/// that fails and a theory that was never reached look the same in the log.
/// A ladder cannot be uninformative: whichever rung produces the document, the
/// log says so, and the rungs that did not are named with the reason.
@MainActor
final class ArticleExtractor: NSObject, WKNavigationDelegate {
    struct Article: Codable, Sendable {
        let title: String?
        let byline: String?
        let content: String?
        let textContent: String?
        let excerpt: String?
        let siteName: String?
        let length: Int?
        let dir: String?
        /// The article as drawable blocks, from `ReaderBlocks.js`. Optional
        /// because the WebKit rungs produce an article without them, and
        /// because a walker failure must not lose the article itself.
        var blocks: [ReaderBlock]?
        /// What the walker refused, for the log: `["svg": 10]`.
        var droppedElements: [String: Int]?
        var blockError: String?
        /// How many nodes had to be moved out of `<head>` because the page
        /// never closed it. Zero on a well-formed page.
        var repairedNodes: Int?
        /// The address the page was actually fetched from, after redirects.
        ///
        /// Not the same thing as the link in the feed, and the difference is
        /// what relative links inside the article resolve against. A feed that
        /// hands out `feeds.feedburner.com/...` or an `http://` address that
        /// redirects to `https://` gives a base whose host or path is not the
        /// article's own, and every `/section/other` in the prose would then
        /// point at the wrong site entirely.
        ///
        /// Optional because an article restored from an older cache will not
        /// have one; callers fall back to the feed's link, which is what the
        /// reader used for everything before this existed.
        var resolvedURL: URL?
    }

    enum ExtractionError: Error, LocalizedError {
        case scriptMissing
        case fetchFailed(String)
        case badEncoding
        case noArticle
        case tooShort(Int)
        case timedOut
        case isPDF
        /// WebKit's own content process died, so no navigation callback will
        /// ever arrive. Distinct from `timedOut` because the cause is not slowness.
        case contentProcessTerminated
        /// Every rung of the ladder was tried and none produced a document.
        case noStrategyWorked

        var errorDescription: String? {
            switch self {
            case .scriptMissing: "Reader script not bundled"
            case .fetchFailed(let s): "Couldn\u{2019}t fetch article: \(s)"
            case .badEncoding: "Article encoding not recognised"
            case .noArticle: "No article content found on this page"
            case .tooShort(let n): "Article content too thin (\(n) characters)"
            case .timedOut: "The page took too long to load"
            case .isPDF: "This link is a PDF document"
            case .contentProcessTerminated: "The page renderer stopped unexpectedly"
            case .noStrategyWorked: "The page wouldn\u{2019}t load by any route"
            }
        }
    }

    // MARK: - The ladder

    /// One way of getting fetched HTML into something Readability can read.
    ///
    /// The order is deliberate. The first rung is exactly what the extractor
    /// has always done, so a machine where that works — every macOS 26 machine
    /// — takes it, succeeds, and never sees the rest. The ladder is dead code
    /// on a healthy Mac and a diagnosis on a broken one.
    ///
    /// The rungs also separate the field of causes rather than merely offering
    /// more chances. Rungs 1 and 2 are both *substitute-data* loads: WebKit
    /// takes bytes we hand it and pretends they arrived from the network.
    /// Rungs 3 and 4 are *real resource loads*, which enter WebKit's loader by
    /// a different door entirely. Rung 5 does not involve WebKit at all. So a
    /// log that says "1 and 2 failed, 3 worked" means something quite precise,
    /// and so does one that says "1, 2, 3 and 4 all failed".
    enum Strategy: CaseIterable {
        /// No WebKit at all. Mozilla's Readability, the same bundled file the
        /// other rungs evaluate, run over a LinkeDOM document inside
        /// JavaScriptCore.
        ///
        /// First, and that is the fix rather than the diagnosis. It is the one
        /// rung with no content process, no XPC, no navigation and no window,
        /// so it cannot fail the way the others do; it is the only rung whose
        /// output could be checked against the WebKit path on the developer's
        /// own machine before shipping; and on the five pages checked it is at
        /// parity or better on every axis and two to five times faster.
        case javaScriptCore
        /// What the extractor has always done, unchanged, including the
        /// content rule list.
        case htmlString
        /// The same substitute-data machinery, entered through the API Apple
        /// added in macOS 12 to carry a real request and a real response.
        /// WebKit's own source routes this into the same `loadDataImpl` as
        /// rung 1, so agreement between the two is expected and is itself a
        /// finding: it puts the fault below the API surface. Disagreement
        /// would put it above.
        case simulatedRequest
        /// A real resource load, over a private URL scheme, answered from the
        /// bytes URLSession already fetched. No substitute data anywhere in
        /// the path, and no second trip to the network.
        case schemeHandler
        /// A real resource load from a temporary file. Different again from
        /// the scheme handler: `file:` goes through a sandbox-extension
        /// handshake that a private scheme does not.
        case fileURL

        /// Short enough to read in a log, specific enough to act on.
        var name: String {
            switch self {
            case .javaScriptCore: "JavaScriptCore"
            case .htmlString: "loadHTMLString"
            case .simulatedRequest: "loadSimulatedRequest"
            case .schemeHandler: "schemeHandler"
            case .fileURL: "fileURL"
            }
        }

        /// Position in the log line, so "rung 3 of 5" reads without counting.
        var position: Int { (Strategy.allCases.firstIndex(of: self) ?? 0) + 1 }
    }

    /// The rung that has been winning, and how many articles in a row.
    ///
    /// Static, so it survives between articles and is reset by relaunching.
    /// Deliberately **not** persisted to `UserDefaults`: a remembered winner
    /// would make every later log say only "the winner won", and the walk down
    /// the ladder is the diagnosis.
    private static var winner: Strategy?
    private static var winStreak = 0
    private static var lockedStrategy: Strategy?

    /// How many articles a rung must win in a row before the ladder stops
    /// being walked. One win could be luck on a page that happened to be easy;
    /// two is a pattern, and walking the ladder twice doubles what a single
    /// pasted log is worth.
    private static let winsBeforeLocking = 2

    /// How long a rung is given **after** its navigation commits.
    ///
    /// Commit proves the machinery works, so from that point patience is the
    /// right instinct: a 1.6 MB page on an 8 GB laptop is entitled to take its
    /// time parsing. Measured here, a 1.6 MB page parses in 0.14s, so three
    /// seconds is twenty times the observed cost and still keeps four failed
    /// WebKit rungs inside the reader's own 25s backstop.
    private static let committedBudget: TimeInterval = 3.0

    /// How long a rung is given **before** its navigation commits.
    ///
    /// A rung that has not committed has produced nothing, and on the machine
    /// this ladder was built for it never will: the DOM sits at exactly 39
    /// characters from the first tick to the last, unchanged across five app
    /// versions, four document sizes and two blocker settings. Measured here,
    /// a real article commits in about 150 ms. Nine hundred milliseconds is
    /// six times that, and it keeps the whole five-rung walk shorter than the
    /// single ten-second timeout it replaces.
    private static let uncommittedBudget: TimeInterval = 0.9

    /// How often to ask the DOM whether it is ready.
    ///
    /// 100ms is well under the cost of being wrong: a page that is ready in
    /// 200ms used to wait out the whole 10s timeout, so the poll pays for
    /// itself many times over on the first article.
    private static let domPollInterval: UInt64 = 100_000_000

    /// Below this share of the HTML we handed over, the DOM is not the document
    /// we loaded.
    ///
    /// A `WKWebView` starts out holding an empty document, about 39 characters
    /// of `<html><head></head><body></body></html>`, and **that empty document
    /// already reports `readyState` as `complete`**. So `readyState` alone
    /// cannot tell "the article is parsed" from "the article has not arrived
    /// and may never". Measured on this machine, a real article's DOM comes
    /// back at 62% to 68% of the HTML handed over, because `outerHTML`
    /// normalises as it serialises. Ten per cent sits well clear of both.
    ///
    /// A single-page app with scripts disabled still holds every character it
    /// was served, so this does not mistake "no article in the document" for
    /// "no document".
    private static let minimumDOMShare = 0.10

    // MARK: - Per-extraction state

    private var webView: WKWebView!
    private var readabilityScript: String = ""

    /// What the current rung's navigation delegate has seen. Reset per rung.
    ///
    /// These four flags are the point of this release. Until now the extractor
    /// implemented only `didFinish`, `didFail`, `didFailProvisionalNavigation`
    /// and `webViewWebContentProcessDidTerminate`, none of which ever fired, so
    /// nobody could tell a load that stalled inside WebKit's document loader
    /// from one the content process never began. `policyAsked`, `provisional`
    /// and `committed` are the three places a navigation can die, in order.
    private var policyAsked = false
    private var provisional = false
    private var committed = false
    private var rendererDied = false
    private var navigationFailure: String?
    /// The largest DOM the current rung ever reported. On the failing machine
    /// this is 39 — the empty skeleton — and that number is the single most
    /// useful thing in the reporter's log, so the failure line carries it.
    private var largestDOM = 0
    /// How many navigations the current rung has been asked to allow.
    private var navigationsAllowed = 0
    /// Set once this rung refused a navigation. WebKit reports a refusal as a
    /// cancelled provisional navigation, which is indistinguishable from a real
    /// failure at the delegate; without this the rung would abandon the very
    /// document it just protected.
    private var refusedNavigation = false

    // MARK: - Subresource blocking

    /// Blocks the things an article references. It does NOT list `document`,
    /// and that omission is the whole point.
    ///
    /// Handing WebKit a base URL makes it resolve and fetch every subresource
    /// the HTML references — images, stylesheets, fonts, scripts, tracking
    /// beacons — from the live site, and `didFinish` does not fire until all of
    /// them settle. One beacon that never answers and it never fires at all.
    ///
    /// Readability parses structure. Measured on a 1 MB BBC page with 125
    /// images, 71 scripts and 23 stylesheets, one condition per process: 106 ms
    /// with this rule against 855 ms with no rule at all, and the same 8,161
    /// characters of body text either way.
    ///
    /// A side effect worth having: opening an article no longer downloads that
    /// page's trackers and beacons into a hidden web view.
    private static let blockAllLoads = #"""
    [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document","popup"]},"action":{"type":"block"}}]
    """#
    /// Changed with the rule. A stored list compiled from the old JSON would
    /// otherwise be found on disk and reused for ever, so the identifier
    /// carries the rule's version.
    private static let ruleListID = "cc.jorviksoftware.JorvikDailyNews.extractor.blockSubresources.v2"

    /// Whether the extractor refuses subresource loads.
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews blockSubresources -bool NO
    ///     defaults delete cc.jorviksoftware.JorvikDailyNews blockSubresources
    ///
    /// On by default. Applied identically to every WebKit rung, so it is one
    /// variable across the ladder rather than five.
    ///
    /// Read through `object(forKey:)` rather than `bool(forKey:)`, which answers
    /// false for a key that was never set and would ship the blocker off for
    /// everyone.
    static let blockSubresourcesKey = "blockSubresources"

    static var blocksSubresources: Bool {
        UserDefaults.standard.object(forKey: blockSubresourcesKey) as? Bool ?? true
    }

    /// One line for the launch header, so a log says which mode produced it.
    static var configSummary: String {
        "config: subresource blocking "
            + (blocksSubresources ? "ON" : "OFF (blockSubresources=NO) — subresources will be fetched")
            + (pinnedStrategy.map { ", reader pinned to \($0.name)" } ?? ", reader ladder ON")
    }

    /// Compiled once per machine and then found on disk, so this costs nothing
    /// after the first article. Returns nil if compilation fails, in which case
    /// extraction proceeds as before rather than not at all.
    private static func subresourceBlocker() async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else {
            jdnLog("extractor: no content rule store — subresources will be fetched")
            return nil
        }
        if let found = await withCheckedContinuation({ (c: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: ruleListID) { list, _ in c.resume(returning: list) }
        }) {
            return found
        }
        return await withCheckedContinuation { (c: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: ruleListID, encodedContentRuleList: blockAllLoads) { list, error in
                if let error { jdnLog("extractor: subresource blocklist failed to compile — \(error.localizedDescription)") }
                c.resume(returning: list)
            }
        }
    }

    // MARK: - Web view construction

    private func makeWebView(blocker: WKContentRuleList?, schemeHandler: BytesSchemeHandler? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        // Ephemeral data store — don't persist cookies across launches.
        config.websiteDataStore = .nonPersistent()
        // Disable page-script execution entirely. Readability runs on the
        // static DOM that came down in the HTML, not on anything a page
        // script would render later; for SPAs that needed JS to render
        // their article body, we already fall back to the live page.
        // Turning page scripts off stops them ever calling `crypto.subtle`,
        // which is what reaches the system keychain and triggers the
        // "WebCrypto Master Key" prompt — no amount of JS-level stubbing
        // is reliable because sites can beat `.atDocumentStart` in races
        // or refuse the redefinition entirely (Ars Technica, 2026-04).
        // `evaluateJavaScript` still works and is how we inject Readability.
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePrefs
        if let blocker { config.userContentController.add(blocker) }
        if let schemeHandler {
            config.setURLSchemeHandler(schemeHandler, forURLScheme: BytesSchemeHandler.scheme)
        }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        view.navigationDelegate = self
        host(view)
        return view
    }

    /// Put the web view in a real window, because WebKit may refuse to load
    /// into one that is not.
    ///
    /// Apple tightened this in iOS 16 — the forum thread is titled "iOS 16
    /// kills WKWebView instances unattached to a ViewController" and the
    /// reporter's case is ours exactly, a headless web view used only to scrape
    /// — and WebKit says so plainly in its own log: "Not eagerly reloading the
    /// view because it is not currently visible."
    ///
    /// Hosting is **not** established as the cure. JDN 1.4.4 shipped it, the
    /// log confirms it happened, and the DOM was still 39 characters. It stays
    /// because it costs nothing and removes a variable; the self-test below
    /// measures whether it makes any difference at all on the failing machine,
    /// which is a thing nobody has yet measured.
    ///
    /// `alphaValue` is 0.01 and not 0, following `WKZombie`, whose author hit
    /// the same wall: at zero WebKit may count the view as invisible, and 1% is
    /// imperceptible. It goes in **below** every existing subview, which
    /// `WKZombie` does not have to care about and we do: their host window has
    /// no interface, ours is the newspaper, and a full-size view at 1% alpha
    /// sitting on top would swallow every click.
    @discardableResult
    private func host(_ view: WKWebView) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first,
              let contentView = window.contentView else {
            jdnLog("extract: no window to host the web view — WebKit may refuse to load")
            return false
        }
        // Its own modest frame, not the window's. WebKit's test is whether the
        // view is in a window and not hidden, not how large it is, and nothing
        // here is ever drawn: Readability reads the DOM, and page scripts and
        // subresources are both off, so no media query or layout pass can
        // change what it sees.
        //
        // Sizing it to the window put a 1280x1440 layer behind the newspaper
        // for the length of every extraction, which the compositor blends on
        // every frame. 1024x768 is 43% of the pixels and is the viewport this
        // extractor used before it was hosted at all, so the DOM sees exactly
        // what it always did.
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.alphaValue = 0.01
        contentView.addSubview(view, positioned: .below, relativeTo: nil)
        if !Self.hostingLogged {
            Self.hostingLogged = true
            jdnLog("extract: hosting web views in \(window.className)")
        }
        return true
    }

    /// Hosting is logged once a run, not once a web view. The ladder builds up
    /// to four of them per article and the line says the same thing every time.
    private static var hostingLogged = false

    /// Take a web view out of service for good.
    ///
    /// The ladder builds up to four of them per article, so this matters more
    /// than it did. Clearing the delegate first is not tidiness: a retired view
    /// is still `isLoading`, and a late `didFail` arriving from rung 1 while
    /// rung 3 is in flight would report rung 1's failure against rung 3's
    /// state.
    private func retire(_ view: WKWebView?) {
        guard let view else { return }
        view.navigationDelegate = nil
        view.stopLoading()
        if view.superview != nil { view.removeFromSuperview() }
    }

    // MARK: - Entry point

    /// How long the article's own HTTP request is given.
    ///
    /// Named rather than derived. It used to be `timeout / 2`, half the whole
    /// extraction budget, which is a coupling nobody would guess from the call
    /// site: changing the extraction timeout silently changed the fetch's.
    ///
    /// **12 seconds**, raised from 10 on 2026-09-09. `spectrum.ieee.org` was
    /// measured three times at the app's own request shape and returned the
    /// same 469,053 bytes in 5.89s, 13.77s and 5.22s. A 10-second allowance
    /// sits inside that spread, so the page succeeded or failed on the toss of
    /// a coin. 12s covers the common case and still gives up on a dead host
    /// inside the reader's patience.
    ///
    /// Known limitation: it does **not** cover the 13.77s observation. Chosen
    /// deliberately as a compromise rather than sized to the worst case, since
    /// a slow host should not be able to hold the reader for much longer.
    private static let fetchTimeout: TimeInterval = 12

    /// Below this many characters, a page is not an article.
    ///
    /// **250, lowered from 500 on 2026-09-10**, and the old figure was
    /// throwing away real posts. Pairing every thin extraction in a day's log
    /// with its URL shows a sharp boundary that 500 sat well above:
    ///
    /// | chars   | what the links actually were                          |
    /// |---------|-------------------------------------------------------|
    /// | 19–226  | product landing pages, Show HN links, a Guardian      |
    /// |         | picture page, a video page — genuinely no article     |
    /// | 258–283 | two Six Colors podcast notes, an iamcal microblog     |
    /// |         | entry — the whole post, correctly extracted           |
    ///
    /// So a 283-character microblog post was rejected, sent to the live page,
    /// and the reader got an error for an article that had extracted
    /// perfectly. Below 250 the live page is the right answer, because a
    /// product homepage should be shown as a page.
    ///
    /// Tunable, because the boundary is a judgement about what counts as a
    /// post and one day of one person's feeds is a small sample:
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews minimumArticleLength -int 400
    /// Smallest body worth handing to the parser when the status was an error.
    ///
    /// An error page is usually a few hundred bytes of apology. This is not a
    /// judgement about whether an article is present — Readability makes that
    /// call — only a floor below which asking is pointless.
    static let minimumBodyWorthReading = 2048

    /// `nonisolated` so it can be a default argument: a default is evaluated
    /// at the call site, which may be anywhere.
    nonisolated static var minimumArticleLength: Int {
        let stored = UserDefaults.standard.object(forKey: "minimumArticleLength") as? Int
        guard let stored, stored > 0 else { return 250 }
        return stored
    }

    func extract(url: URL, minimumLength: Int = ArticleExtractor.minimumArticleLength,
                 timeout: TimeInterval = 20,
                 followingFrame: Bool = false) async throws -> Article {
        jdnLog("extract: begin \(url.absoluteString)")
        guard let path = Bundle.main.path(forResource: "Readability", ofType: "js"),
              let js = try? String(contentsOfFile: path, encoding: .utf8) else {
            jdnLog("extract: FAILED — Readability.js missing from the bundle")
            throw ExtractionError.scriptMissing
        }
        self.readabilityScript = js

        // Not awaited. The self-test is the diagnosis and rung 1 is the fix,
        // and the reader should never wait on the diagnosis: the probes touch
        // WebKit and rung 1 does not, so they cannot interfere.
        Task { @MainActor [weak self] in await self?.runSelfTestOnce() }

        let blocker = Self.blocksSubresources ? await Self.subresourceBlocker() : nil
        if Self.blocksSubresources && blocker == nil {
            jdnLog("extract: subresource blocking UNAVAILABLE — falling back to fetching them")
        }

        let page = try await fetchHTML(url: url, timeout: Self.fetchTimeout)

        // Which of two different failures happened, because they are not the
        // same news for the reader.
        //
        // If a rung produced a document and Readability found no article in
        // it, the page is a link list or an index and there was nothing to lay
        // out — true of `catastrophe.co.za`, which parsed cleanly in 0.02s and
        // has no article on it. If no rung produced a document at all, the
        // loader is the fault. Rethrowing whichever rung failed last conflated
        // them and reported "The page took too long to load" for a ladder that
        // had exhausted itself in four seconds.
        var sawDocumentWithoutArticle = false
        for strategy in Self.ladder() {
            switch await attempt(strategy, page: page, blocker: blocker, minimumLength: minimumLength) {
            case .article(let article):
                Self.recordWin(strategy)
                var resolved = article
                resolved.resolvedURL = page.url
                if page.url != url {
                    jdnLog("extract: links resolve against \(page.url.absoluteString) "
                           + "after a redirect from \(url.absoluteString)")
                }
                return resolved
            case .documentButNoArticle(let error):
                // A real document arrived and Readability read it. Its verdict
                // is about the page, not about the loader, so the WebKit rungs
                // would only reach the same conclusion more slowly.
                //
                // Rung 1 is the exception, and deliberately so. LinkeDOM parses
                // with htmlparser2 rather than a spec tree builder: it does not
                // synthesise an implicit `<tbody>` and it does not run the
                // adoption-agency algorithm on misnested inline tags. On every
                // page measured that changed nothing, but "every page measured"
                // is five, so a page where LinkeDOM alone finds no article gets
                // a second opinion from WebKit before the reader gives up.
                guard strategy == .javaScriptCore, Self.lockedStrategy == nil,
                      Self.pinnedStrategy == nil else {
                    Self.recordWin(strategy)
                    throw error
                }
                jdnLog("extract: \(strategy.name) found no article — asking WebKit for a second opinion")
                sawDocumentWithoutArticle = true
                continue
            case .noDocument:
                continue
            }
        }
        // A page can be a frame around somebody else's document and carry
        // almost no text of its own. Asked only now, when the page's own
        // content has already failed, so a real article that merely embeds a
        // video or a map is never redirected away from.
        if !followingFrame,
           let frame = EmbeddedArticle.candidate(in: page.html, base: page.url) {
            jdnLog("extract: no article on the page itself — following its frame to "
                   + frame.absoluteString)
            do {
                return try await extract(url: frame, minimumLength: minimumLength,
                                         timeout: timeout, followingFrame: true)
            } catch {
                // The frame is a guess. If it does not hold an article either,
                // the reader must hear about the page it actually asked for,
                // not about a frame it never mentioned.
                jdnLog("extract: the frame held no article either — \(error.localizedDescription)")
            }
        }

        if let status = page.badStatus {
            jdnLog("extract: nothing readable, and the body arrived under HTTP \(status)")
            throw ExtractionError.fetchFailed("HTTP \(status)")
        }

        jdnLog("extract: every rung failed — no document by any route")
        // Each rung's own reason is already logged above this line, so the
        // error only has to name which of the two failures this was.
        throw sawDocumentWithoutArticle
            ? ExtractionError.noArticle
            : ExtractionError.noStrategyWorked
    }

    /// Pin the extractor to one rung and disable the ladder.
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews readerStrategy schemeHandler
    ///     defaults delete cc.jorviksoftware.JorvikDailyNews readerStrategy
    ///
    /// The value is a `Strategy.name`. This is how a rung gets A/B tested on a
    /// machine three thousand miles away without another release: one command,
    /// one relaunch, one line in the log. Nine releases went by without one of
    /// these, and each of them cost a day.
    static let strategyKey = "readerStrategy"

    static var pinnedStrategy: Strategy? {
        guard let name = UserDefaults.standard.string(forKey: strategyKey), !name.isEmpty else { return nil }
        return Strategy.allCases.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The order to try rungs in: a pinned rung alone, else the locked winner
    /// first and everything else in declaration order.
    private static func ladder() -> [Strategy] {
        if let pinned = pinnedStrategy { return [pinned] }
        guard let locked = lockedStrategy else { return Strategy.allCases }
        return [locked] + Strategy.allCases.filter { $0 != locked }
    }

    private static func recordWin(_ strategy: Strategy) {
        guard lockedStrategy == nil else { return }
        if winner == strategy {
            winStreak += 1
        } else {
            winner = strategy
            winStreak = 1
        }
        guard winStreak >= winsBeforeLocking else { return }
        lockedStrategy = strategy
        jdnLog("extract: locking on to \(strategy.name) for the rest of this run")
    }

    private enum RungOutcome {
        /// A document arrived and Readability found an article in it.
        case article(Article)
        /// A document arrived; Readability found nothing usable in it. Stop the
        /// ladder — that is a verdict about the page, not about the loader.
        case documentButNoArticle(Error)
        /// No document arrived. Try the next rung.
        case noDocument(Error)
    }

    // MARK: - One rung

    private func attempt(_ strategy: Strategy, page: FetchedPage,
                         blocker: WKContentRuleList?, minimumLength: Int) async -> RungOutcome {
        let label = "rung \(strategy.position)/\(Strategy.allCases.count) \(strategy.name)"
        let started = Date()

        if strategy == .javaScriptCore {
            return await attemptNative(page: page, label: label, started: started, minimumLength: minimumLength)
        }

        policyAsked = false
        provisional = false
        committed = false
        rendererDied = false
        navigationFailure = nil
        largestDOM = 0
        navigationsAllowed = 0
        refusedNavigation = false

        var scratchDir: URL?
        defer {
            if let scratchDir { try? FileManager.default.removeItem(at: scratchDir) }
        }

        let handler = strategy == .schemeHandler
            ? BytesSchemeHandler(data: page.data, mimeType: page.mimeType, encoding: page.textEncodingName)
            : nil
        let view = makeWebView(blocker: blocker, schemeHandler: handler)
        retire(webView)
        webView = view

        switch strategy {
        case .htmlString:
            // Byte for byte what every previous release did.
            view.loadHTMLString(page.html, baseURL: page.url)
        case .simulatedRequest:
            var request = URLRequest(url: page.url)
            request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
            _ = view.loadSimulatedRequest(request, response: page.response, responseData: page.data)
        case .schemeHandler:
            _ = view.load(URLRequest(url: BytesSchemeHandler.documentURL))
        case .fileURL:
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("jdn-reader-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let file = dir.appendingPathComponent("article.html")
                try Self.withBaseHref(page.html, page.url).write(to: file, atomically: true, encoding: .utf8)
                scratchDir = dir
                view.loadFileURL(file, allowingReadAccessTo: dir)
            } catch {
                jdnLog("extract: \(label) — could not stage a temp file (\(error.localizedDescription))")
                retire(view)
                return .noDocument(ExtractionError.fetchFailed(error.localizedDescription))
            }
        case .javaScriptCore:
            break   // handled above
        }

        guard let domChars = await awaitDocument(view, expecting: page.html.count) else {
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            jdnLog("extract: \(label) — NO DOCUMENT after \(elapsed)s"
                   + " [dom \(largestDOM) of \(page.html.count)"
                   + " policy=\(policyAsked ? "yes" : "no")"
                   + " provisional=\(provisional ? "yes" : "no")"
                   + " commit=\(committed ? "yes" : "no")"
                   + (rendererDied ? " renderer=DIED" : "")
                   + (navigationFailure.map { " error=\($0)" } ?? "")
                   + "]")
            retire(view)
            return .noDocument(rendererDied ? ExtractionError.contentProcessTerminated : ExtractionError.timedOut)
        }

        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        jdnLog("extract: \(label) — DOCUMENT OK, \(domChars) chars in \(elapsed)s")

        // The scheme-handler and file rungs changed `document.baseURI`, so the
        // `<base href>` injected above is what puts relative links back on the
        // real site. Readability reads `baseURI` and nothing else.
        let script = readabilityScript
            + "\n;JSON.stringify(new Readability(document.cloneNode(true)).parse());"
        let result = try? await view.evaluateJavaScript(script)
        retire(view)
        return interpret(result as? String, label: label, minimumLength: minimumLength)
    }

    /// Rung 5. No web view, no navigation, no content process.
    private func attemptNative(page: FetchedPage, label: String,
                               started: Date, minimumLength: Int) async -> RungOutcome {
        let outcome = await NativeReader.shared.extract(html: page.html, url: page.url,
                                                        readability: readabilityScript)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        switch outcome {
        case .failure(let why):
            jdnLog("extract: \(label) — UNAVAILABLE after \(elapsed)s: \(why)")
            return .noDocument(ExtractionError.fetchFailed(why))
        case .success(let json):
            jdnLog("extract: \(label) — DOCUMENT OK, parsed in \(elapsed)s")
            return interpret(json, label: label, minimumLength: minimumLength)
        }
    }

    /// Turn Readability's JSON into an outcome. Shared by every rung so the
    /// WebKit path and the JavaScriptCore path cannot judge an article
    /// differently.
    /// A decoding error in the terms that identify it: which key, what type.
    /// `localizedDescription` on a `DecodingError` is famously useless — it
    /// says "The data couldn't be read because it isn't in the correct
    /// format" and names nothing.
    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? "the top level" : keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "null where \(type) was required at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupt at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return "\(decoding)"
        }
    }

    private func interpret(_ json: String?, label: String, minimumLength: Int) -> RungOutcome {
        // Three different outcomes, and `try?` reported all of them as the
        // first one. A page that extracted perfectly could be announced as
        // having no article because a field this app added did not decode,
        // and the log said nothing that would let anybody tell the difference.
        guard let json, json != "null", json != "undefined",
              let data = json.data(using: .utf8) else {
            jdnLog("readability: no article in this page — live page fallback")
            return .documentButNoArticle(ExtractionError.noArticle)
        }
        let article: Article
        do {
            article = try JSONDecoder().decode(Article.self, from: data)
        } catch {
            // Readability found something and we could not read it. That is a
            // fault in this app, not in the page, and it must not be dressed
            // up as an empty page.
            jdnLog("readability: extracted \(data.count) bytes but the reader could not "
                   + "decode them — \(Self.describe(error))")
            return .documentButNoArticle(ExtractionError.noArticle)
        }
        let len = article.length ?? article.textContent?.count ?? 0
        guard len >= minimumLength else {
            jdnLog("readability: only \(len) chars — too thin, live page fallback")
            return .documentButNoArticle(ExtractionError.tooShort(len))
        }
        if let repaired = article.repairedNodes, repaired > 0 {
            jdnLog("readability: the page never closed <head> — moved \(repaired) node(s) "
                   + "into <body> first, as a browser would")
        }
        jdnLog("readability: article of \(len) chars — rendering reader view")
        // Say what the block walker made of it, so the native renderer is
        // observable from its first run rather than judged by eye alone.
        if let blocks = article.blocks {
            var kinds: [String: Int] = [:]
            for block in blocks { kinds[block.kind.rawValue, default: 0] += 1 }
            let kept = kinds.sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let dropped = (article.droppedElements ?? [:]).sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            jdnLog("blocks: \(blocks.count) — \(kept)"
                   + (dropped.isEmpty ? "" : "; dropped \(dropped)"))
        } else if let why = article.blockError {
            jdnLog("blocks: the walker failed — \(why)")
        } else {
            jdnLog("blocks: none produced (a WebKit rung, or the walker is missing)")
        }
        return .article(article)
    }

    // MARK: - Waiting for a document

    /// Ask the DOM directly whether it is ready, instead of waiting to be told.
    ///
    /// `didFinish` was only ever a proxy for "the DOM is ready", and on macOS 27
    /// the proxy stopped tracking the thing it stands for. So the DOM itself is
    /// the thing to ask, and the navigation delegate is demoted to a witness:
    /// it records where the load got to and logs it, and decides nothing.
    ///
    /// Returns the DOM's character count, or nil if no document arrived.
    ///
    /// The two budgets are the whole trick. Before commit the loop is
    /// impatient, because a load that has not committed on the failing machine
    /// never does; after commit it is patient, because commit proves the
    /// machinery works and the page is merely large. That asymmetry is what
    /// lets five rungs fit inside less time than one rung used to take.
    private func awaitDocument(_ view: WKWebView, expecting handedOver: Int) async -> Int? {
        let started = Date()
        while true {
            try? await Task.sleep(nanoseconds: Self.domPollInterval)
            if Task.isCancelled { return nil }
            if rendererDied || navigationFailure != nil { return nil }

            let probe = "document.readyState + '|' + document.documentElement.outerHTML.length"
            if let answer = (try? await view.evaluateJavaScript(probe)) as? String {
                let parts = answer.split(separator: "|", maxSplits: 1)
                let state = parts.first.map(String.init) ?? ""
                let domChars = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                largestDOM = max(largestDOM, domChars)
                // `interactive` is accepted as well as `complete`, and that is
                // safe here rather than merely convenient: page scripts are
                // disabled and subresources are refused, so nothing can add to
                // the document after parsing finishes. The DOM at `interactive`
                // is the final DOM.
                if state == "complete" || state == "interactive" {
                    let plausible = handedOver == 0
                        || Double(domChars) >= Double(handedOver) * Self.minimumDOMShare
                    if plausible { return domChars }
                }
            }

            let elapsed = Date().timeIntervalSince(started)
            if committed {
                if elapsed >= Self.committedBudget { return nil }
            } else if elapsed >= Self.uncommittedBudget {
                return nil
            }
        }
    }

    // MARK: - Self-test

    /// Three trivial loads, once per run, before the first article.
    ///
    /// This is the cheapest measurement in the build and the one nobody has
    /// taken. It loads sixty characters of HTML — no site, no subresources, no
    /// size, no encoding — and reports whether WebKit will produce a document
    /// from it at all. If `loadHTMLString` cannot manage sixty characters, then
    /// every theory about rule lists, document size, service workers and
    /// picture memory is finished in one line, and the answer was always one
    /// second away.
    ///
    /// The three probes vary one thing each: hosting (JDN 1.4.4's fix, never
    /// actually tested against its opposite on the failing machine) and
    /// `suppressesIncrementalRendering`, which withholds the first paint until
    /// a load completes and is therefore the one configuration flag whose whole
    /// job is to make a web view wait.
    private static var selfTestDone = false

    /// When the self-test last found WebKit rendering nothing at all, or nil
    /// if it has not.
    ///
    /// Recorded because the app knew and could not say. On 10 September 2026
    /// the bisect reported at **06:59:19** that even 75 characters would not
    /// load; the three live-page failures that followed at 07:01, 07:04 and
    /// 07:09 were that, and the same build served a live page perfectly at
    /// 08:08 once the spell had passed. Without this, a live-page failure has
    /// nothing to correlate against, and I read those three as a regression in
    /// a probe I had changed two hours earlier.
    ///
    /// Reported, never acted on. This machine's WebKit fault clears on its own
    /// after roughly twenty minutes, so a verdict from earlier in a session is
    /// evidence about the past and not a prediction. Anything that skipped
    /// work on the strength of it would eventually skip a page that was fine.
    nonisolated(unsafe) static var webKitRenderedNothingAt: Date?

    /// One line naming the last such verdict, for a log written later.
    static var webKitVerdict: String {
        guard let at = webKitRenderedNothingAt else {
            return "the self-test found WebKit rendering normally"
        }
        let ago = Int(Date().timeIntervalSince(at))
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "the self-test found WebKit rendering NOTHING at \(f.string(from: at)), "
            + "\(ago)s ago"
    }

    private func runSelfTestOnce() async {
        guard !Self.selfTestDone else { return }
        Self.selfTestDone = true
        await selfTest(name: "hosted, suppressed", hosted: true, suppressed: true)
        await selfTest(name: "hosted, not suppressed", hosted: true, suppressed: false)
        await selfTest(name: "not hosted", hosted: false, suppressed: true)
        await schemeSelfTest()
        await sizeBisect()
    }

    /// Finds the size at which a substitute-data load stops working.
    ///
    /// The reporter's 1.4.5 log established that `loadHTMLString` is not
    /// broken on macOS 27, only broken *above a size*: sixty characters loaded
    /// twelve times out of twelve, and thirteen real reader documents of 8,449
    /// to 17,065 characters all came back as the 39-character empty skeleton.
    /// The same bytes over a real resource load rendered every time. That looks
    /// like an IPC boundary, where WebKit hands a large payload to the renderer
    /// by shared memory rather than inline.
    ///
    /// Between 75 and 8,449 is not a number anyone can act on. This narrows it
    /// to a bracket by bisection, which is five or six loads rather than a
    /// ladder of fixed sizes, and states the answer in one line. The point is a
    /// bug report Apple can reproduce, and one local question: the video embed
    /// host page is 511 characters, so whether video works on an affected Mac
    /// depends entirely on which side of the limit that falls.
    private func sizeBisect() async {
        var low = Self.selfTestHTML.count
        var high = Self.bisectCeiling

        guard await !substituteDataLoads(chars: high) else {
            jdnLog("selftest: bisect — \(high) chars loaded, so there is no limit below that here")
            return
        }

        // The lower bound has to be MEASURED, not assumed.
        //
        // The first version of this took `low` on faith because the probes
        // above had just loaded that size. On 2026-09-09 every WebKit load in
        // the process was failing, and this reported "substitute data works to
        // 75 chars and fails by 330" — a threshold it had never tested in that
        // pass — and then concluded from it that video would not play. Both
        // statements were fabricated from an assumption. When nothing works,
        // the honest answer is that nothing works.
        guard await substituteDataLoads(chars: low) else {
            Self.webKitRenderedNothingAt = Date()
            jdnLog("selftest: bisect — even \(low) chars did not load, so WebKit is "
                   + "rendering nothing at all here and there is no size limit to find")
            return
        }
        for _ in 0..<Self.bisectSteps where high - low > Self.bisectPrecision {
            let mid = low + (high - low) / 2
            if await substituteDataLoads(chars: mid) { low = mid } else { high = mid }
        }
        jdnLog("selftest: bisect — substitute data works to \(low) chars and fails by \(high)")
        let embed = Self.videoEmbedChars
        let verdict = embed <= low ? "below the limit, so video should play"
                    : embed >= high ? "ABOVE the limit, so video will not play"
                    : "inside the bracket, so video is uncertain"
        jdnLog("selftest: bisect — the video embed host page is \(embed) chars, \(verdict)")
    }

    /// One probe: build a document of about `chars` characters and report
    /// whether `loadHTMLString` produced it.
    ///
    /// The padding is a run of ordinary text inside a `<p>`, not a comment,
    /// because a comment invites a parser to discard it and would make a
    /// success indistinguishable from the empty document.
    private func substituteDataLoads(chars: Int) async -> Bool {
        let shell = "<html><head><title>t</title></head><body><p></p></body></html>"
        let padding = String(repeating: "jdn ", count: max(1, (chars - shell.count) / 4))
        let html = shell.replacingOccurrences(of: "<p></p>", with: "<p>\(padding)</p>")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        host(view)
        let started = Date()
        view.loadHTMLString(html, baseURL: nil)
        var arrived = 0
        while Date().timeIntervalSince(started) < Self.bisectProbeTimeout {
            try? await Task.sleep(nanoseconds: Self.domPollInterval)
            if let answer = (try? await view.evaluateJavaScript("document.documentElement.outerHTML.length")) as? Int,
               answer > Self.emptyDocumentChars, answer >= html.count / 2 {
                arrived = answer
                break
            }
        }
        retire(view)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        jdnLog("selftest: bisect \(html.count) chars — \(arrived > 0 ? "OK (\(arrived) chars)" : "DEAD") in \(elapsed)s")
        return arrived > 0
    }

    /// Where the bisect starts looking. Above every reader document seen in the
    /// reporter's logs, so a pass here means the fault is not size at all.
    private static let bisectCeiling = 32_768
    /// Enough halvings to take 75...32,768 down to the precision below.
    private static let bisectSteps = 10
    /// Stop when the bracket is this narrow. Finer than this tells a bug report
    /// nothing more and costs another second on an affected machine.
    private static let bisectPrecision = 256
    /// A failing probe waits this long before it is called dead. The successful
    /// probes in the reporter's log all answered inside 0.41s.
    private static let bisectProbeTimeout: TimeInterval = 1.0
    /// A web view that has loaded nothing still answers this length, so a probe
    /// must clear it before a proportion of the payload means anything. Half of
    /// a small payload is *below* it — at 74 characters the empty skeleton is
    /// 39, which passes "at least half" and reports a load that never happened.
    /// Measured on macOS 26.6.2, where the probe wrongly said OK.
    private static let emptyDocumentChars = "<html><head></head><body></body></html>".count
    /// `ReaderSheet.youTubeEmbedHTML` rendered with an 11-character video id.
    /// Vimeo's is 442, so YouTube is the one that decides it.
    private static let videoEmbedChars = 511

    /// The fourth probe, and the one the reader now depends on.
    ///
    /// The three above all use `loadHTMLString`, which is a *substitute-data*
    /// load: WebKit takes bytes it is handed and pretends they came from the
    /// network. This one asks for the same sixty characters over a private URL
    /// scheme, which is a *real resource load* and enters WebKit's loader by a
    /// different door.
    ///
    /// That distinction is the whole question. If `loadHTMLString` is dead and
    /// this is alive, the fault is in the substitute-data path, the reader's
    /// fallback in `ReaderSheet` will save the reporter, and the answer is to
    /// stop using substitute data anywhere. If both are dead the fault is
    /// something app-wide and every theory about the loader is finished.
    private func schemeSelfTest() async {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePrefs
        let handler = BytesSchemeHandler(data: Data(Self.selfTestHTML.utf8),
                                         mimeType: "text/html", encoding: "utf-8")
        config.setURLSchemeHandler(handler, forURLScheme: BytesSchemeHandler.scheme)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        host(view)
        let started = Date()
        view.load(URLRequest(url: BytesSchemeHandler.documentURL))
        var chars = 0
        while Date().timeIntervalSince(started) < 1.0 {
            try? await Task.sleep(nanoseconds: Self.domPollInterval)
            if let answer = (try? await view.evaluateJavaScript("document.documentElement.outerHTML.length")) as? Int,
               answer > 60 {
                chars = answer
                break
            }
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        if chars > 0 {
            jdnLog("selftest: \(BytesSchemeHandler.scheme): real resource load — OK (\(chars) chars in \(elapsed)s)")
        } else {
            jdnLog("selftest: \(BytesSchemeHandler.scheme): real resource load — DEAD (60 chars never arrived in \(elapsed)s)")
        }
        retire(view)
    }

    private static let selfTestHTML = "<html><head><title>t</title></head><body><p>jdn self test</p></body></html>"

    private func selfTest(name: String, hosted: Bool, suppressed: Bool) async {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = suppressed
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        if hosted { host(view) }
        let started = Date()
        view.loadHTMLString(Self.selfTestHTML, baseURL: nil)
        var chars = 0
        while Date().timeIntervalSince(started) < 1.0 {
            try? await Task.sleep(nanoseconds: Self.domPollInterval)
            if let answer = (try? await view.evaluateJavaScript("document.documentElement.outerHTML.length")) as? Int,
               answer > 60 {
                chars = answer
                break
            }
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        if chars > 0 {
            jdnLog("selftest: loadHTMLString \(name) — OK (\(chars) chars in \(elapsed)s)")
        } else {
            jdnLog("selftest: loadHTMLString \(name) — DEAD (60 chars never arrived in \(elapsed)s)")
        }
        retire(view)
    }

    // MARK: - Networking

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

    /// Everything a rung might need from one fetch: the raw bytes for the
    /// strategies that want to be handed a response, and the decoded string for
    /// the strategies that want text.
    private struct FetchedPage {
        /// The error status the body arrived under, if it did. Reported only
        /// when no article is found, so a page served under a wrong header
        /// still opens while a genuine 404 still says 404.
        var badStatus: Int?

        let data: Data
        let html: String
        let response: URLResponse
        let url: URL

        var mimeType: String {
            let declared = response.mimeType ?? ""
            return declared.isEmpty ? "text/html" : declared
        }
        var textEncodingName: String? { response.textEncodingName }
    }

    private func fetchHTML(url: URL, timeout: TimeInterval) async throws -> FetchedPage {
        var request = URLRequest(url: url)
        // Many sites gate content or layout on a desktop-browser UA; the raw
        // URLSession default UA gets redirected to mobile or refused outright.
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = max(5, timeout)

        let (data, response): (Data, URLResponse)
        do {
            jdnLog("fetch: requesting \(url.absoluteString) (timeout \(request.timeoutInterval)s)")
            (data, response) = try await BoundedFetch.data(for: request,
                                                          on: .shared,
                                                          limit: BoundedFetch.markupLimit)
        } catch {
            jdnLog("fetch: FAILED — \(error.localizedDescription)")
            throw ExtractionError.fetchFailed(error.localizedDescription)
        }
        jdnLog("fetch: \((response as? HTTPURLResponse)?.statusCode ?? -1) — \(data.count) bytes")
        var badStatus: Int?

        // A bad status with a real body is still worth reading.
        //
        // The status used to end it, and the body was never looked at. Plenty
        // of sites get this wrong: a client-routed path is served as the app's
        // shell with a 404 because the route only exists once JavaScript runs,
        // a misconfigured CDN returns 500 with the page intact, a soft-404
        // serves the article and the wrong header.
        //
        // Readability decides. If it finds an article in the body then there
        // was an article, whatever the header claimed; if it finds nothing the
        // reader hears about the status exactly as before, so a genuine 404
        // still reports a genuine 404. `line.klet.app/about/` is the case that
        // prompted this and is NOT rescued by it — 7,220 bytes carrying 55
        // characters of text, all of it the title — which is the point: this
        // changes what happens to pages that have something to show.
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            guard data.count >= Self.minimumBodyWorthReading else {
                jdnLog("fetch: rejected on status \(http.statusCode) — "
                       + "\(data.count) bytes is too little to be an article")
                throw ExtractionError.fetchFailed("HTTP \(http.statusCode)")
            }
            jdnLog("fetch: status \(http.statusCode) but \(data.count) bytes arrived — "
                   + "reading it anyway, and reporting the status only if there is no article")
            badStatus = http.statusCode
        }

        // Detect PDFs before we ever treat the bytes as HTML — by declared
        // Content-Type or the "%PDF" magic number. Otherwise Readability runs
        // on the raw PDF stream and "succeeds" with pages of mojibake.
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("application/pdf")
            || data.starts(with: Data([0x25, 0x50, 0x44, 0x46])) {   // %PDF
            throw ExtractionError.isPDF
        }

        let finalURL = response.url ?? url
        let html: String
        if let utf8 = String(data: data, encoding: .utf8) {
            html = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            html = latin1
        } else {
            throw ExtractionError.badEncoding
        }
        jdnLog("extract: \(html.count) chars fetched, base \(finalURL.absoluteString)")
        return FetchedPage(badStatus: badStatus, data: data, html: html,
                           response: response, url: finalURL)
    }

    // MARK: - Base URL rewriting

    /// Put a `<base href>` at the top of the document's head.
    ///
    /// Rungs 3 and 4 load the article from a private scheme or from a temporary
    /// file, so `document.baseURI` is no longer the article's own URL, and
    /// Readability's `_fixRelativeUris` reads exactly that property when it
    /// makes links and images absolute. The injected tag puts it back.
    ///
    /// It goes *first* in the head because the first `<base href>` in document
    /// order is the one the parser honours, so a page that ships its own base
    /// tag cannot override ours.
    static func withBaseHref(_ html: String, _ url: URL) -> String {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let tag = "<base href=\"\(escaped)\">"
        // After `<head>` if there is one, otherwise after `<html>`, otherwise
        // at the very front. Never before the doctype, which would drop the
        // parser into quirks mode and change the DOM we are trying to read.
        for opener in ["<head", "<html"] {
            guard let start = html.range(of: opener, options: .caseInsensitive) else { continue }
            guard let close = html.range(of: ">", range: start.upperBound..<html.endIndex) else { continue }
            var out = html
            out.insert(contentsOf: tag, at: close.upperBound)
            return out
        }
        return tag + html
    }

    deinit {
        // Not via `retire()`, which is main-actor isolated. A view left behind
        // would sit under the interface for the life of the app, one per
        // article opened. `superview` is main-actor isolated too, so the whole
        // check goes inside the assumption rather than only the removal.
        guard let view = webView else { return }
        MainActor.assumeIsolated {
            if view.superview != nil { view.removeFromSuperview() }
        }
    }

    // MARK: - WKNavigationDelegate

    // These four record where a navigation got to and log it. They resume
    // nothing and decide nothing: `awaitDocument` reads the DOM, and the DOM is
    // the only thing Readability cares about. The value here is diagnostic —
    // `policy`, `provisional`, `commit` are the three gates a load passes
    // through, in order, and the first one that never reports is where the
    // fault lives.

    /// Allow the rung's own document and refuse everything after it.
    ///
    /// A page can move itself with `<meta http-equiv="refresh">` even with
    /// scripts disabled, and a 1.6 MB Wired article does exactly that: it
    /// commits our document and then navigates away to a `text/plain`
    /// response, throwing away the DOM Readability was about to read. Whether
    /// that mattered used to depend on which of the two won a race with the
    /// DOM poll. Refusing it makes every rung read the document it was given,
    /// and only that document, which is the whole point of handing WebKit
    /// bytes we have already fetched.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard isCurrent(webView) else {
            decisionHandler(.allow)
            return
        }
        policyAsked = true
        navigationsAllowed += 1
        guard navigationsAllowed == 1 else {
            refusedNavigation = true
            jdnLog("webview: refused a second navigation to \(navigationAction.request.url?.host ?? "?")")
            decisionHandler(.cancel)
            return
        }
        jdnLog("webview: policy asked — \(navigationAction.request.url?.scheme ?? "?")")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if isCurrent(webView) {
            jdnLog("webview: response \(navigationResponse.response.mimeType ?? "?")")
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(webView) else { return }
            self.provisional = true
            jdnLog("webview: provisional started")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(webView) else { return }
            self.committed = true
            jdnLog("webview: committed")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(webView) else { return }
            jdnLog("webview: didFinish")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(webView) else { return }
            guard !(cancelled && self.refusedNavigation) else { return }
            self.navigationFailure = message
            jdnLog("webview: didFail — \(message)")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(webView) else { return }
            guard !(cancelled && self.refusedNavigation) else { return }
            self.navigationFailure = message
            jdnLog("webview: provisional FAILED — \(message)")
        }
    }

    /// WebKit's content process died. Without this the app sees nothing at
    /// all: no `didFinish`, no `didFail`, no `didFailProvisionalNavigation`,
    /// just silence until the rung's own budget runs out.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(webView) else { return }
            self.rendererDied = true
            jdnLog("webview: RENDERER DIED — usually memory pressure")
        }
    }

    /// Whether a callback belongs to the rung that is running now.
    ///
    /// `retire` clears the delegate, but a callback already in flight when a
    /// rung is abandoned still arrives, and a stale `didFail` from rung 1
    /// landing during rung 3 would abandon a healthy load on the strength of a
    /// dead one's error. Identity is the exact test.
    private func isCurrent(_ view: WKWebView) -> Bool { webView === view }
}

// MARK: - Rung 3's scheme handler

/// Serves one document, from bytes already in memory, over a private scheme.
///
/// This is rung 3's whole reason for existing. `loadHTMLString`,
/// `loadData`, `loadSimulatedRequest` and `loadAlternateHTML` all become a
/// WebKit `SubstituteData` main load, which is delivered to the parser by a
/// route of its own that has no error path at all: if the hand-off is lost, no
/// delegate fires, `estimatedProgress` stays at its initial 0.1, and the web
/// view waits for ever. That is precisely the signature in five logs. A custom
/// scheme is a *real* resource load, so it does not go near that route.
///
/// Everything except the one document is refused, which also gives rung 3 the
/// subresource blocking for free.
@MainActor
final class BytesSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "jdn-article"
    static let documentURL = URL(string: "\(scheme)://read/article")!

    private let data: Data
    private let mimeType: String
    private let encoding: String?
    /// A task that WebKit has stopped must never be told anything again, or the
    /// process traps. Cheaper to remember them than to guess.
    private var stopped = Set<ObjectIdentifier>()

    init(data: Data, mimeType: String, encoding: String?) {
        self.data = data
        self.mimeType = mimeType
        self.encoding = encoding
    }

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated { serve(urlSchemeTask) }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated { _ = stopped.insert(ObjectIdentifier(urlSchemeTask)) }
    }

    private func serve(_ task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard !stopped.contains(id) else { return }
        guard task.request.url == Self.documentURL else {
            // A subresource the article referenced. Refuse it and say nothing
            // to the log: a busy page has hundreds and they are all irrelevant.
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let response = URLResponse(url: Self.documentURL, mimeType: mimeType,
                                   expectedContentLength: data.count, textEncodingName: encoding)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

// MARK: - Rung 5: Readability without WebKit

/// Mozilla's Readability, run over a LinkeDOM document inside JavaScriptCore.
///
/// This is the rung that cannot fail the way the others can. There is no
/// content process, no XPC, no navigation, no run loop to lose a timer on and
/// no window to be absent from: HTML goes into a `JSContext` on a private
/// serial queue and JSON comes back. Every WebKit rung above ships blind,
/// because the fault is only reproducible on one machine three thousand miles
/// away. This one is testable here, on every article, before it is released —
/// which is the only property that actually breaks the loop of one release per
/// theory.
///
/// `Readability.js` is the same bundled file the WebKit rungs evaluate, byte for
/// byte, and it is passed in rather than re-read, so extraction quality cannot
/// diverge between the two paths. `LinkeDOM.js` supplies the `document` that
/// WebKit would otherwise have supplied. It is linkedom 0.18.13, bundled
/// unminified so that it can be read and diffed rather than trusted:
///
///     esbuild entry-linkedom.mjs --bundle --format=iife \
///         --global-name=linkedom --platform=browser --target=es2020 \
///         --outfile=Resources/LinkeDOM.js
///
/// where `entry-linkedom.mjs` is one line:
///
///     export { parseHTML } from 'linkedom';
///
/// ## Measured against the WebKit rung, five live pages, this machine
///
/// phys.org, BBC Sport and WIRED — the reporter's own three articles from the
/// newest log — plus a 1.2 MB Wikipedia page and an Ars Technica index, release
/// build. Body text **character for character identical** on the four article
/// pages, and `article.length` identical too: 5177, 5249, 5212, 94270. The Ars
/// index, which is a link list rather than an article, differs by 24 characters
/// of whitespace in its navigation.
///
/// Bylines come out *better*, for a reason worth writing down. Every WebKit rung
/// sets `allowsContentJavaScript = false`, and with scripting off WebKit
/// discards the contents of `<script>` elements — including
/// `application/ld+json`, which is where news sites put the headline, the byline
/// and the date. So the WebKit path has never been able to read a page's
/// JSON-LD. Measured: BBC "Phil Cartwright" and Wikipedia "Contributors to
/// Wikimedia projects" are found here and are `null` through WebKit, and
/// Wikipedia's title comes back as "Isle of Man" rather than
/// "Isle of Man - Wikipedia".
///
/// A fresh context costs 15 ms to build, and the slowest of the five pages took
/// 0.98 s end to end against 1.76 s through `loadHTMLString`.
final class NativeReader: @unchecked Sendable {
    static let shared = NativeReader()

    enum Outcome {
        case success(String)
        case failure(String)
    }

    /// Its own queue, because a `JSContext` belongs to the thread that made it
    /// and because parsing a megabyte of HTML has no business on the main one.
    ///
    /// A plain `DispatchQueue` and not a `Thread` with a raised stack: the
    /// worry was that a dispatch worker's 512 KB stack would turn a deeply
    /// nested document into "Maximum call stack size exceeded". Measured, it
    /// does not — `<div>` nested 5,000 deep parses and serialises identically
    /// on a dispatch queue and on an 8 MB thread. Real articles are two orders
    /// of magnitude shallower, so the extra machinery bought nothing.
    private let queue = DispatchQueue(label: "cc.jorviksoftware.JorvikDailyNews.nativereader")

    /// How long the reader waits for JavaScriptCore before moving on.
    ///
    /// Not a cancellation: nothing in the public JavaScriptCore API can stop a
    /// running script, so an abandoned run keeps going until it finishes. It
    /// exists so a pathological page cannot hold the ladder open — the next
    /// rung starts, and the reader's own 25s backstop is no longer the only
    /// thing standing between a bad page and a spinner that never stops.
    /// Measured here, the slowest of five real pages was 0.98s.
    private static let budget: TimeInterval = 8.0

    func extract(html: String, url: URL, readability: String) async -> Outcome {
        let absolute = url.absoluteString
        return await withCheckedContinuation { continuation in
            let slot = Slot(continuation)
            queue.async { [self] in
                slot.finish(run(html: html, url: absolute, readability: readability))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.budget) {
                slot.finish(.failure("JavaScriptCore did not answer within \(Int(Self.budget))s"))
            }
        }
    }

    /// Holds the continuation and the one flag that says it has been used.
    ///
    /// Two things race for it, the worker and the watchdog, and resuming a
    /// `CheckedContinuation` twice is a crash rather than a warning.
    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?

        init(_ continuation: CheckedContinuation<Outcome, Never>) {
            self.continuation = continuation
        }

        func finish(_ outcome: Outcome) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: outcome)
        }
    }

    /// Everything below runs on `queue` and nowhere else.
    ///
    /// A fresh context per article, not a cached one. The cache saved 15 ms and
    /// cost two things worth more than that: the previous article's document
    /// stayed reachable until the collector got round to it, and a setup
    /// failure was remembered for the life of the run, so one bad launch
    /// disabled the rung for ever.
    private func run(html: String, url: String, readability: String) -> Outcome {
        guard let dom = Self.linkeDOM else {
            return .failure("LinkeDOM.js missing from the bundle")
        }
        guard let context = JSContext() else {
            return .failure("no JavaScript context")
        }
        var thrown: [String] = []
        context.exceptionHandler = { _, exception in
            thrown.append(exception?.toString() ?? "unknown JavaScript error")
        }
        Self.installGlobals(context)

        let started = Date()
        context.evaluateScript(dom, withSourceURL: URL(string: "jdn:LinkeDOM.js"))
        context.evaluateScript(readability, withSourceURL: URL(string: "jdn:Readability.js"))
        if let walker = Self.bundledScript("ReaderBlocks") {
            context.evaluateScript(walker, withSourceURL: URL(string: "jdn:ReaderBlocks.js"))
        }
        context.evaluateScript(Self.glue, withSourceURL: URL(string: "jdn:glue.js"))
        if let first = thrown.first {
            jdnLog("nativereader: setup failed — \(first)")
            return .failure(first)
        }

        guard let function = context.objectForKeyedSubscript("__jdnExtract"), !function.isUndefined else {
            return .failure("the reader function was not defined")
        }
        let value = function.call(withArguments: [html, url, Self.minimumInlineSVGSide])
        if let first = thrown.first { return .failure(first) }
        guard let json = value?.toString(), json != "undefined" else {
            return .failure("the reader returned nothing")
        }
        jdnLog("nativereader: \(html.count) chars of HTML read in"
               + " \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return .success(json)
    }

    /// The DOM shim, read once per launch. 491 KB, and it does not change under
    /// a running app.
    private static let linkeDOM: String? = {
        guard let path = Bundle.main.path(forResource: "LinkeDOM", ofType: "js"),
              let js = try? String(contentsOfFile: path, encoding: .utf8) else {
            jdnLog("nativereader: LinkeDOM.js missing from the bundle")
            return nil
        }
        return js
    }()

    /// A bundled JavaScript resource, or nil with a line in the log.
    ///
    /// `ReaderBlocks.js` is optional by design: without it an article still
    /// extracts and the WebKit rungs still draw it, so a missing walker
    /// degrades the reader rather than breaking it.
    private static func bundledScript(_ name: String) -> String? {
        guard let path = Bundle.main.path(forResource: name, ofType: "js"),
              let js = try? String(contentsOfFile: path, encoding: .utf8) else {
            jdnLog("nativereader: \(name).js missing from the bundle")
            return nil
        }
        return js
    }

    /// Below this, on its longer side, an inline `<svg>` is furniture rather
    /// than artwork and is dropped.
    ///
    /// Sized from a measurement: of 135 inline SVGs on one real page, 96 were
    /// 40x40 or 80x80 icons and **not one of the 135 carried an `aria-label`
    /// or a `<title>`** to say what it was, so size is the only honest
    /// discriminator available. 64 keeps the two large ones — a masthead at
    /// 436x144 — and drops the icons. Same principle as the 48-pixel floor on
    /// pictures, which exists so a tracking pixel cannot blot the page.
    static let minimumInlineSVGSide: Double = 64

    /// The three globals a bare `JSContext` does not have and this rung needs.
    ///
    /// A `JSContext` is ECMAScript and nothing else. It has no `atob`, no
    /// `Buffer` and no `URL`, and the first two of those are not cosmetic:
    ///
    /// **`atob`.** LinkeDOM ships its HTML entity table as base64 and decodes
    /// it with `atob`, falling back to `Buffer` when there isn't one. With
    /// neither, LinkeDOM throws `ReferenceError: Can't find variable: Buffer`
    /// and the rung is dead. With a `Buffer` stub that returns its input —
    /// which is what shipped — it does not throw, and instead decodes named
    /// entities against a garbage table, silently. Measured against the WebKit
    /// path on the reporter's own articles: 17 corrupted entities in one BBC
    /// article and 13 in a Wikipedia page, `&quot;` reaching the reader as
    /// `&amp;quot;` and `&nbsp;` as `Ĵbsp;`. Nothing thrown, nothing logged.
    ///
    /// **`URL`.** Readability calls `new URL(uri, baseURI).href` in
    /// `_fixRelativeUris` and `new URL(str)` in `_isUrl`, both inside a
    /// `try`/`catch`. Without the global, every catch fires: measured, 31
    /// links left relative in a Wikipedia article, 8 on an Ars page, 3 on the
    /// BBC. They resolve against the reader sheet's own base URL, which is not
    /// the article's, so they lead nowhere.
    ///
    /// With both in place the body text is character-for-character identical to
    /// what `loadHTMLString` + Readability produces on this machine, on all
    /// five pages tested including the reporter's own three.
    ///
    /// `console` is not stubbed: `JSContext` already provides one.
    private static func installGlobals(_ context: JSContext) {
        let decodeBase64: @convention(block) (String) -> String? = { input in
            var padded = input.trimmingCharacters(in: .whitespacesAndNewlines)
            while padded.count % 4 != 0 { padded += "=" }
            guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) else {
                return nil
            }
            // A binary string: one UTF-16 code unit per byte, which is what
            // `atob` returns and what LinkeDOM's decoder then indexes.
            return String(decoding: data.map { UInt16($0) }, as: UTF16.self)
        }
        context.setObject(decodeBase64, forKeyedSubscript: "atob" as NSString)

        // Foundation resolves the URL; the JavaScript side is only a shape.
        // Readability reads `.href` and nothing else, but the other components
        // are cheap and stop a future Readability update from silently
        // catching again.
        let resolve: @convention(block) (String, String?) -> [String: Any]? = { relative, base in
            let baseURL = base.flatMap { URL(string: $0) }
            guard let resolved = URL(string: relative, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            return [
                "href": resolved.absoluteString,
                "protocol": resolved.scheme.map { $0 + ":" } ?? "",
                "hostname": resolved.host ?? "",
                "host": (resolved.host ?? "") + (resolved.port.map { ":\($0)" } ?? ""),
                "pathname": resolved.path,
                "search": resolved.query.map { "?" + $0 } ?? "",
                "hash": resolved.fragment.map { "#" + $0 } ?? "",
            ]
        }
        context.setObject(resolve, forKeyedSubscript: "__jdnResolveURL" as NSString)
        context.evaluateScript("""
        globalThis.URL = function (input, base) {
          var parts = __jdnResolveURL(String(input),
                                      base === undefined || base === null ? null : String(base));
          if (!parts) { throw new TypeError('Invalid URL: ' + input); }
          for (var key in parts) { this[key] = parts[key]; }
        };
        globalThis.URL.prototype.toString = function () { return this.href; };
        """)
    }

    /// `documentURI` as well as `baseURI`, because Readability compares the
    /// two: when they match it treats `#fragment` links as same-page and leaves
    /// them alone, which is what a real browser does and what the WebKit rungs
    /// produce.
    private static let glue = """
    globalThis.__jdnExtract = function (html, url, minSvgSide) {
      var doc = linkedom.parseHTML(html).document;
      try { Object.defineProperty(doc, 'baseURI', { value: url, configurable: true }); } catch (e) {}
      try { Object.defineProperty(doc, 'documentURI', { value: url, configurable: true }); } catch (e) {}
      // Before Readability sees it: put back the <body> a spec parser would
      // have opened. See `repairHeadBody`.
      var repaired = 0;
      try { if (globalThis.__jdnRepairTree) repaired = __jdnRepairTree(doc); } catch (e) {}
      var article = new Readability(doc).parse();
      if (!article) return null;
      article.repairedNodes = repaired;
      // Blocks are produced in the same pass, from the same DOM, so the
      // native renderer and the WebKit fallback can never disagree about
      // what the article said.
      try {
        var walked = JSON.parse(__jdnBlocks(article.content, minSvgSide));
        article.blocks = walked.blocks;
        article.droppedElements = walked.dropped;
      } catch (e) {
        article.blocks = null;
        article.blockError = String(e);
      }
      return JSON.stringify(article);
    };
    """
}
