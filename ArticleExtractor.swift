import Foundation
import WebKit

/// Fetches an article URL via URLSession, then loads the HTML into a
/// WKWebView and runs Mozilla Readability.js against it. URLSession handles
/// the networking (so we can set headers, follow redirects, and — critically
/// — avoid the NSURLErrorCancelled that a hidden WKWebView hits when it has
/// no host window on macOS). WKWebView is only responsible for DOM + JS
/// execution for Readability.
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
            }
        }
    }

    private var webView: WKWebView!
    private var continuation: CheckedContinuation<Article, Error>?
    private var readabilityScript: String = ""
    private var timeoutTask: Task<Void, Never>?
    private var domReadyPollTask: Task<Void, Never>?
    /// Extraction runs once. `didFinish` and the DOM poll below are two routes
    /// to the same place, and on a machine where both work they race.
    private var extractionStarted = false
    /// Set once the load has been retried with the blocker off, so a document
    /// that is empty for its own reasons cannot loop.
    private var retriedWithoutBlocker = false
    private var emptyDOMTicks = 0
    /// What was handed to the web view, to compare the DOM against.
    private var handedOverChars = 0
    private var loadedHTML = ""
    private var loadedBaseURL: URL?

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

    /// How many consecutive ticks of `complete` with an empty DOM before the
    /// document is called lost rather than late.
    ///
    /// Five ticks is half a second. Below that the load may simply be slower
    /// than the first tick, which is the ordinary case on a large page or a
    /// busy machine, and waiting is right. Above it the document is not
    /// coming.
    private static let emptyDOMTicksBeforeRetry = 5

    /// How often to ask the DOM whether it is ready.
    ///
    /// 100ms is well under the cost of being wrong: a page that is ready in
    /// 200ms used to wait out the whole 10s timeout, so the poll pays for
    /// itself many times over on the first article.
    private static let domPollInterval: UInt64 = 100_000_000

    /// A rule list that blocks every load the page asks for.
    ///
    /// This is the difference between the reader working and hanging. Handing
    /// WebKit a base URL makes it resolve and fetch every subresource the HTML
    /// references — images, stylesheets, fonts, scripts, tracking beacons —
    /// from the live site, and `didFinish` does not fire until all of them
    /// settle. One beacon that never answers and it never fires at all, so the
    /// extractor waits for ever on downloads it is going to throw away.
    ///
    /// Readability parses structure. Measured on three articles that hung or
    /// crawled: blocking subresources took them to 0.11s, 0.11s and 0.15s from
    /// two stalls and 13.06s — and the DOM came out the same, 38,179 characters
    /// of body text against 38,178. Nothing Readability reads is fetched over
    /// the network.
    ///
    /// The base URL still goes in, so relative links in the extracted article
    /// resolve correctly. Only the *loading* is refused.
    ///
    /// A side effect worth having: opening an article no longer downloads that
    /// page's trackers and beacons into a hidden web view.
    /// Blocks the things an article references. It does NOT list `document`,
    /// and that omission is the whole point.
    ///
    /// This was `{"url-filter":".*"}` with no resource types, which reads as
    /// "block every load". On macOS 26 that left the `loadHTMLString` document
    /// alone. On macOS 27 it does not: the document arrived empty, so
    /// `document.readyState` reported `complete` for an empty document and
    /// Readability correctly found no article in it. The tell was in the
    /// timings — 1.6 MB of HTML and 164 KB both reached `complete` in about
    /// 140 ms, because nothing was being parsed either time.
    ///
    /// Naming the resource types means a document load cannot be caught by the
    /// rule whatever a future WebKit decides to classify it as. Measured on a
    /// 1 MB BBC page with 125 images, 71 scripts and 23 stylesheets, one
    /// condition per process: 106 ms with this rule against 122 ms with the
    /// blanket one and 855 ms with no rule at all, and the same 8,161
    /// characters of body text in all three. It blocks as well and cannot
    /// block the article.
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
    /// On by default, and it should stay on: it is what stopped articles hanging
    /// on beacons that never answer. The switch exists because a
    /// block-everything rule list is a blunt instrument. If a WebKit version
    /// ever applied it to the main document of a `loadHTMLString` rather than
    /// only to that document's subresources, the navigation would never
    /// complete, and the symptom would be indistinguishable from the fault the
    /// blocker cures. One command then tells the two apart.
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

    private func makeWebView(blocker: WKContentRuleList?) -> WKWebView {
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
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        view.navigationDelegate = self
        return view
    }

    func extract(url: URL, minimumLength: Int = 500, timeout: TimeInterval = 20) async throws -> Article {
        jdnLog("extract: begin \(url.absoluteString)")
        guard let path = Bundle.main.path(forResource: "Readability", ofType: "js"),
              let js = try? String(contentsOfFile: path, encoding: .utf8) else {
            jdnLog("extract: FAILED — Readability.js missing from the bundle")
            throw ExtractionError.scriptMissing
        }
        self.readabilityScript = js
        jdnLog("extract: Readability.js loaded (\(js.count) chars)")

        let blocker = Self.blocksSubresources ? await Self.subresourceBlocker() : nil
        if Self.blocksSubresources {
            jdnLog("extract: subresource blocking \(blocker == nil ? "UNAVAILABLE — falling back to fetching them" : "on")")
        } else {
            jdnLog("extract: subresource blocking OFF by preference — subresources will be fetched")
        }
        self.webView = makeWebView(blocker: blocker)

        let (html, finalURL) = try await fetchHTML(url: url, timeout: timeout / 2)

        self.extractionStarted = false
        self.retriedWithoutBlocker = false
        self.emptyDOMTicks = 0
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((timeout / 2) * 1_000_000_000))
                guard !Task.isCancelled else {
                    jdnLog("extract: timeout task cancelled (a navigation callback got there first)")
                    return
                }
                await MainActor.run {
                    guard let self, let cont = self.continuation else {
                        jdnLog("extract: timeout fired but the continuation was already resumed")
                        return
                    }
                    // What the web view was doing when it ran out of time.
                    // These separate three states that look identical from
                    // outside: a load that never began (progress 0, not
                    // loading), one stuck partway (progress parks around
                    // 0.6), and a DOM that is ready while `didFinish` is
                    // withheld. Read synchronously, because a wedged web view
                    // may never answer an asynchronous probe.
                    let view = self.webView
                    let progress = view?.estimatedProgress ?? -1
                    let loading = view?.isLoading ?? false
                    let currentURL = view?.url?.absoluteString ?? "nil"
                    jdnLog("extract: TIMED OUT after \(timeout / 2)s waiting on the web view"
                           + " (estimatedProgress \(String(format: "%.2f", progress)),"
                           + " isLoading \(loading), url \(currentURL))")
                    // `document.readyState`, for the log alone. Nothing waits
                    // on it. The web view is captured strongly so it outlives
                    // this extractor long enough to answer; if the content
                    // process is gone it never answers, and the absence of the
                    // line is itself the finding.
                    view?.evaluateJavaScript("document.readyState") { value, error in
                        if let state = value as? String {
                            jdnLog("extract: post-timeout document.readyState = \(state)")
                        } else {
                            jdnLog("extract: post-timeout readyState probe returned nothing"
                                   + " — \(error?.localizedDescription ?? "no value, no error")")
                        }
                    }
                    self.continuation = nil
                    self.domReadyPollTask?.cancel()
                    view?.stopLoading()
                    cont.resume(throwing: ExtractionError.timedOut)
                }
            }
            jdnLog("extract: handing \(html.count) chars to the web view, base \(finalURL.absoluteString)")
            self.handedOverChars = html.count
            self.loadedHTML = html
            self.loadedBaseURL = finalURL
            self.webView.loadHTMLString(html, baseURL: finalURL)
            self.startDOMReadyPoll()
        }
    }

    /// Ask the DOM directly whether it is ready, instead of waiting to be told.
    ///
    /// `didFinish` was only ever a proxy for "the DOM is ready", and on macOS 27
    /// the proxy stopped tracking the thing it stands for. Measured from a
    /// reporter's log: `document.readyState` was **complete** while
    /// `estimatedProgress` sat at 0.10 and `isLoading` stayed true, so
    /// `didFinish` never arrived and extraction waited out its entire 10s
    /// timeout on a page that had been ready almost immediately. Four articles,
    /// four fallbacks, no reader views, on pages that had fully parsed.
    ///
    /// Readability reads the DOM and nothing else, so the DOM is the right thing
    /// to ask. `didFinish` stays as the fast path where it works, and
    /// `extractionStarted` keeps the two from racing.
    ///
    /// `interactive` is accepted as well as `complete`, and that is safe here
    /// rather than merely convenient: page scripts are disabled and every
    /// subresource is refused, so nothing can add to the document after parsing
    /// finishes. The DOM at `interactive` is the final DOM.
    private func startDOMReadyPoll() {
        domReadyPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.domPollInterval)
                guard !Task.isCancelled, let self,
                      !self.extractionStarted, self.continuation != nil,
                      let view = self.webView else { return }
                // Both facts in one round trip. `readyState` alone is not
                // enough: the empty document a web view starts with already
                // reports `complete`, so the DOM's own size is what separates
                // "the article is parsed" from "the article has not arrived".
                let probe = "document.readyState + '|' + document.documentElement.outerHTML.length"
                let raw = try? await view.evaluateJavaScript(probe)
                guard let answer = raw as? String else { continue }
                let parts = answer.split(separator: "|", maxSplits: 1)
                guard let state = parts.first.map(String.init),
                      state == "complete" || state == "interactive" else { continue }
                let domChars = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                guard !self.extractionStarted, self.continuation != nil else { return }

                let plausible = self.handedOverChars == 0
                    || Double(domChars) >= Double(self.handedOverChars) * Self.minimumDOMShare
                if !plausible {
                    // Late, or lost. Keep waiting for half a second before
                    // deciding, because the first tick can easily land before a
                    // large document has parsed.
                    self.emptyDOMTicks += 1
                    guard self.emptyDOMTicks >= Self.emptyDOMTicksBeforeRetry else { continue }
                    guard !self.retriedWithoutBlocker, !self.loadedHTML.isEmpty,
                          let baseURL = self.loadedBaseURL else {
                        // Nothing left to try. Let the timeout take it to the
                        // live page, and say why rather than reporting "no
                        // article found", which is true of this DOM and false
                        // of the article.
                        jdnLog("extract: DOM still holds only \(domChars) chars of"
                               + " \(self.handedOverChars) after \(self.emptyDOMTicks) ticks"
                               + " — the document did not arrive")
                        return
                    }
                    self.retriedWithoutBlocker = true
                    self.emptyDOMTicks = 0
                    jdnLog("extract: DOM holds only \(domChars) chars of \(self.handedOverChars)"
                           + " after \(Self.emptyDOMTicksBeforeRetry) ticks — retrying with"
                           + " subresource blocking OFF")
                    self.webView = self.makeWebView(blocker: nil)
                    self.webView.loadHTMLString(self.loadedHTML, baseURL: baseURL)
                    continue
                }

                jdnLog("extract: DOM ready (readyState=\(state), \(domChars) chars of"
                       + " \(self.handedOverChars))\(self.retriedWithoutBlocker ? " after retry without the blocker" : "")")
                await self.runExtraction()
                return
            }
        }
    }

    // MARK: - Networking

    private func fetchHTML(url: URL, timeout: TimeInterval) async throws -> (html: String, finalURL: URL) {
        var request = URLRequest(url: url)
        // Many sites gate content or layout on a desktop-browser UA; the raw
        // URLSession default UA gets redirected to mobile or refused outright.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = max(5, timeout)

        let (data, response): (Data, URLResponse)
        do {
            jdnLog("fetch: requesting \(url.absoluteString) (timeout \(request.timeoutInterval)s)")
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            jdnLog("fetch: FAILED — \(error.localizedDescription)")
            throw ExtractionError.fetchFailed(error.localizedDescription)
        }
        jdnLog("fetch: \((response as? HTTPURLResponse)?.statusCode ?? -1) — \(data.count) bytes")

        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            jdnLog("fetch: rejected on status \(http.statusCode)")
            throw ExtractionError.fetchFailed("HTTP \(http.statusCode)")
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
        if let html = String(data: data, encoding: .utf8) {
            return (html, finalURL)
        }
        if let html = String(data: data, encoding: .isoLatin1) {
            return (html, finalURL)
        }
        throw ExtractionError.badEncoding
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        jdnLog("webview: didFinish")
        Task { @MainActor [weak self] in
            guard let self else {
                jdnLog("webview: didFinish but the extractor was already gone")
                return
            }
            await self.runExtraction()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        jdnLog("webview: didFail — \(message)")
        Task { @MainActor [weak self] in
            guard let self, let cont = self.continuation else { return }
            self.continuation = nil
            self.timeoutTask?.cancel()
            self.domReadyPollTask?.cancel()
            cont.resume(throwing: ExtractionError.fetchFailed(message))
        }
    }

    /// WebKit's content process died. Without this the app sees nothing at
    /// all: no `didFinish`, no `didFail`, no `didFailProvisionalNavigation`,
    /// just silence until the extractor's own timeout. That is exactly the
    /// signature in the issue #1 reporter's log, and it was unreadable because
    /// this callback was not implemented.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        jdnLog("webview: WEB CONTENT PROCESS TERMINATED — WebKit's renderer died,"
               + " so no navigation callback can arrive. Usually memory pressure.")
        Task { @MainActor [weak self] in
            guard let self, let cont = self.continuation else { return }
            self.continuation = nil
            self.timeoutTask?.cancel()
            self.domReadyPollTask?.cancel()
            cont.resume(throwing: ExtractionError.contentProcessTerminated)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        jdnLog("webview: didFailProvisionalNavigation — \(message)")
        Task { @MainActor [weak self] in
            guard let self, let cont = self.continuation else { return }
            self.continuation = nil
            self.timeoutTask?.cancel()
            self.domReadyPollTask?.cancel()
            cont.resume(throwing: ExtractionError.fetchFailed(message))
        }
    }

    @MainActor
    private func runExtraction() async {
        guard !extractionStarted else { return }
        extractionStarted = true
        domReadyPollTask?.cancel()
        let script = readabilityScript + "\n;JSON.stringify(new Readability(document.cloneNode(true)).parse());"
        do {
            jdnLog("readability: evaluating")
            let result = try await webView.evaluateJavaScript(script)
            jdnLog("readability: returned \(result is String ? "a string of \((result as? String)?.count ?? 0) chars" : String(describing: type(of: result)))")
            guard let cont = continuation else {
                jdnLog("readability: finished but the continuation was already resumed")
                return
            }
            continuation = nil
            timeoutTask?.cancel()

            guard let jsonString = result as? String, jsonString != "null",
                  let data = jsonString.data(using: .utf8) else {
                jdnLog("readability: no article found — falling back to the live page")
                cont.resume(throwing: ExtractionError.noArticle)
                return
            }
            let article = try JSONDecoder().decode(Article.self, from: data)
            let len = article.length ?? article.textContent?.count ?? 0
            if len < 500 {
                jdnLog("readability: only \(len) chars — too short, falling back to the live page")
                cont.resume(throwing: ExtractionError.tooShort(len))
                return
            }
            jdnLog("readability: article of \(len) chars — rendering reader view")
            cont.resume(returning: article)
        } catch {
            jdnLog("readability: threw — \(error.localizedDescription)")
            guard let cont = continuation else { return }
            continuation = nil
            timeoutTask?.cancel()
            cont.resume(throwing: error)
        }
    }
}
