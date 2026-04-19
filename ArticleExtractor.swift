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

        var errorDescription: String? {
            switch self {
            case .scriptMissing: "Reader script not bundled"
            case .fetchFailed(let s): "Couldn\u{2019}t fetch article: \(s)"
            case .badEncoding: "Article encoding not recognised"
            case .noArticle: "No article content found on this page"
            case .tooShort(let n): "Article content too thin (\(n) characters)"
            case .timedOut: "The page took too long to load"
            }
        }
    }

    private let webView: WKWebView
    private var continuation: CheckedContinuation<Article, Error>?
    private var readabilityScript: String = ""
    private var timeoutTask: Task<Void, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        // Ephemeral data store — don't persist cookies, local storage, or
        // WebCrypto keys across launches. Prevents the first-run macOS
        // keychain prompt for "WebCrypto Master Key" that a site's inline
        // script can otherwise trigger on an extraction load.
        config.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    func extract(url: URL, minimumLength: Int = 500, timeout: TimeInterval = 20) async throws -> Article {
        guard let path = Bundle.main.path(forResource: "Readability", ofType: "js"),
              let js = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ExtractionError.scriptMissing
        }
        self.readabilityScript = js

        let (html, finalURL) = try await fetchHTML(url: url, timeout: timeout / 2)

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((timeout / 2) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, let cont = self.continuation else { return }
                    self.continuation = nil
                    self.webView.stopLoading()
                    cont.resume(throwing: ExtractionError.timedOut)
                }
            }
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
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ExtractionError.fetchFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw ExtractionError.fetchFailed("HTTP \(http.statusCode)")
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runExtraction()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let cont = self.continuation else { return }
            self.continuation = nil
            self.timeoutTask?.cancel()
            cont.resume(throwing: ExtractionError.fetchFailed(message))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
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
            let result = try await webView.evaluateJavaScript(script)
            guard let cont = continuation else { return }
            continuation = nil
            timeoutTask?.cancel()

            guard let jsonString = result as? String, jsonString != "null",
                  let data = jsonString.data(using: .utf8) else {
                cont.resume(throwing: ExtractionError.noArticle)
                return
            }
            let article = try JSONDecoder().decode(Article.self, from: data)
            let len = article.length ?? article.textContent?.count ?? 0
            if len < 500 {
                cont.resume(throwing: ExtractionError.tooShort(len))
                return
            }
            cont.resume(returning: article)
        } catch {
            guard let cont = continuation else { return }
            continuation = nil
            timeoutTask?.cancel()
            cont.resume(throwing: error)
        }
    }
}
