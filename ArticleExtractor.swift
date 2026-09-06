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

        var errorDescription: String? {
            switch self {
            case .scriptMissing: "Reader script not bundled"
            case .fetchFailed(let s): "Couldn\u{2019}t fetch article: \(s)"
            case .badEncoding: "Article encoding not recognised"
            case .noArticle: "No article content found on this page"
            case .tooShort(let n): "Article content too thin (\(n) characters)"
            case .timedOut: "The page took too long to load"
            case .isPDF: "This link is a PDF document"
            }
        }
    }

    private var webView: WKWebView!
    private var continuation: CheckedContinuation<Article, Error>?
    private var readabilityScript: String = ""
    private var timeoutTask: Task<Void, Never>?

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
    private static let blockAllLoads = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    private static let ruleListID = "cc.jorviksoftware.JorvikDailyNews.extractor.blockSubresources"

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

        let blocker = await Self.subresourceBlocker()
        jdnLog("extract: subresource blocking \(blocker == nil ? "UNAVAILABLE — falling back to fetching them" : "on")")
        self.webView = makeWebView(blocker: blocker)

        let (html, finalURL) = try await fetchHTML(url: url, timeout: timeout / 2)

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
                    jdnLog("extract: TIMED OUT after \(timeout / 2)s waiting on the web view")
                    self.continuation = nil
                    self.webView.stopLoading()
                    cont.resume(throwing: ExtractionError.timedOut)
                }
            }
            jdnLog("extract: handing \(html.count) chars to the web view, base \(finalURL.absoluteString)")
            self.webView.loadHTMLString(html, baseURL: finalURL)
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
            cont.resume(throwing: ExtractionError.fetchFailed(message))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        jdnLog("webview: didFailProvisionalNavigation — \(message)")
        Task { @MainActor [weak self] in
            guard let self, let cont = self.continuation else { return }
            self.continuation = nil
            self.timeoutTask?.cancel()
            cont.resume(throwing: ExtractionError.fetchFailed(message))
        }
    }

    @MainActor
    private func runExtraction() async {
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
