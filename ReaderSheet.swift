import SwiftUI
import WebKit
import PDFKit
import AppKit

/// Reader view rendered inline inside the main window (not a modal sheet) —
/// the newspaper "turns to" the article, and Back returns to the paper.
struct ReaderView: View {
    let item: FeedItem
    @Environment(AppStore.self) private var store

    @State private var state: ReaderState = .loading

    /// The article's current section, shown in (and editable from) the header
    /// re-classify menu. Seeded from the resolved section when the reader opens.
    @State private var section: String = ""
    @State private var newSectionPrompt = false
    @State private var newSectionName = ""

    enum ReaderState {
        case loading
        case ready(ArticleExtractor.Article)
        case pdf(URL)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: item.id) {
            section = store.classifier.pinnedSection(itemId: item.itemId) ?? item.section
            await extract()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                store.selectedArticle = nil
            } label: {
                Label("Back to Paper", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to the newspaper (Esc)")

            Spacer()

            Text(item.sourceTitle)
                .font(.custom("Charter", size: 11))
                .kerning(1.8)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            sectionMenu

            Button {
                NSWorkspace.shared.open(item.link)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .help("Open the original article in your browser")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .alert("Move to new section", isPresented: $newSectionPrompt) {
            TextField("Section name", text: $newSectionName)
            Button("Move") {
                let trimmed = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { reclassify(to: trimmed) }
                newSectionPrompt = false
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { newSectionPrompt = false }
        } message: {
            Text("Move this article to a new section. The paper learns from this correction.")
        }
    }

    /// Re-classify the current article without leaving the reader. Defaults to
    /// (and ticks) the article's current section so the user can see what it's
    /// filed under, and picking another section pins + trains the classifier
    /// exactly as the right-click "Move to…" menu on the paper does.
    private var sectionMenu: some View {
        Menu {
            ForEach(store.allSections, id: \.self) { s in
                Button {
                    reclassify(to: s)
                } label: {
                    if s == section {
                        Label(s, systemImage: "checkmark")
                    } else {
                        Text(s)
                    }
                }
            }
            Divider()
            Button("New section\u{2026}") {
                newSectionName = ""
                newSectionPrompt = true
            }
        } label: {
            Label(section.isEmpty ? "Section" : section, systemImage: "tag")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Re-classify this article — change the section it files under")
    }

    private func reclassify(to newSection: String) {
        section = newSection
        store.moveArticle(item, to: newSection)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("Turning to the article\u{2026}")
                    .font(.custom("Charter", size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready(let article):
            ReaderWebView(html: renderHTML(article), baseURL: item.link)

        case .pdf(let url):
            PDFReader(url: url)

        case .failed:
            // No clean reader view (link lists like HN, paywalls, SPA-rendered
            // pages). Rather than dead-ending the user out to a browser, render
            // the real page inline in a full web view. The header's "Open in
            // Browser" stays as the escape hatch for anyone who wants it.
            LiveWebView(url: item.link)
        }
    }

    private func extract() async {
        state = .loading
        // Fast path: an obvious .pdf link skips the HTML extractor entirely.
        if item.link.pathExtension.lowercased() == "pdf" {
            state = .pdf(item.link)
            return
        }
        let extractor = ArticleExtractor()
        do {
            let article = try await extractor.extract(url: item.link)
            state = .ready(article)
        } catch ArticleExtractor.ExtractionError.isPDF {
            // PDF without a .pdf extension — detected by content-type / magic.
            state = .pdf(item.link)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func renderHTML(_ article: ArticleExtractor.Article) -> String {
        let css = Self.loadCSS()
        let site = article.siteName ?? item.sourceTitle
        let byline = article.byline ?? ""
        let title = article.title ?? item.title
        let content = article.content ?? ""

        let bylineLine: String
        if byline.isEmpty {
            bylineLine = escape(site)
        } else {
            bylineLine = "\(escape(site)) \u{00B7} \(escape(byline))"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>\(css)</style>
        </head>
        <body>
          <article>
            <header>
              <p class="byline">\(bylineLine)</p>
              <h1>\(escape(title))</h1>
            </header>
            \(content)
          </article>
        </body>
        </html>
        """
    }

    private static func loadCSS() -> String {
        guard let path = Bundle.main.path(forResource: "reader", ofType: "css"),
              let s = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        return s
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - WKWebView wrapper

struct ReaderWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Ephemeral: no keychain prompts, no leftover cookies between
        // sessions. The reader renders static extracted HTML only.
        config.websiteDataStore = .nonPersistent()
        // We're showing extracted + stylesheet-applied HTML. Any residual
        // scripts Readability didn't strip don't need to run — they'd only
        // call trackers or embeds that we don't want in a reader view.
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePrefs
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(html, baseURL: baseURL)
    }
}

// MARK: - Live page fallback

/// Full-fidelity render of the original page, used when article extraction
/// can't produce a clean reader view. Unlike `ReaderWebView` (which shows
/// stripped, script-free reader HTML), this loads the real URL with
/// JavaScript enabled — it's a genuine in-app page render so the user never
/// has to leave for a browser. Ephemeral data store: nothing persists between
/// sessions; back/forward swipe gestures are enabled for normal browsing.
struct LiveWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // Load once — don't reload on every SwiftUI update pass.
        if web.url == nil {
            web.load(URLRequest(url: url))
        }
    }
}

// MARK: - PDF rendering

/// Native PDF reader for items that link straight to a PDF. PDFKit gives a
/// proper document experience — continuous scroll, pinch-zoom, selection,
/// `⌘F` find — rather than the page of mojibake you'd get from running the
/// raw PDF stream through the HTML reader. A spinner covers the view while
/// the (possibly large) file downloads.
private struct PDFReader: View {
    let url: URL
    @State private var loading = true

    var body: some View {
        ZStack {
            PDFKitView(url: url) { loading = false }
            if loading {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Loading PDF\u{2026}")
                        .font(.custom("Charter", size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

/// Bytes are fetched with a Safari user agent (some hosts gate on it) and
/// handed to `PDFDocument(data:)`. `onLoaded` fires once the attempt finishes
/// — success or failure — so the wrapper can dismiss its spinner either way.
struct PDFKitView: NSViewRepresentable {
    let url: URL
    var onLoaded: () -> Void = {}

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .textBackgroundColor

        Task { @MainActor in
            defer { onLoaded() }
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let document = PDFDocument(data: data) else { return }
            view.document = document
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
