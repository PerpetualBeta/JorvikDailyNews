import SwiftUI
import WebKit
import PDFKit
import AVKit
import AVFoundation
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
        case video(VideoTarget)
        case failed(String)
    }

    /// How a video link is played in-app: a YouTube/Vimeo player embedded
    /// chrome-free (as an `<iframe>` in a host page so the player gets a valid
    /// origin), or a native `AVPlayer` for a direct media file.
    enum VideoTarget {
        case youTube(String)   // video id
        case vimeo(String)     // video id
        case native(URL)
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

            Button {
                store.excludeSource(item)
                store.selectedArticle = nil
            } label: {
                Label("Exclude Source", systemImage: "nosign")
            }
            .help("Never show \(store.displayHost(for: item) ?? "this source") in your paper again")

            Spacer()

            // Always-visible provenance. The source title names the feed; the
            // host names where the material actually lives. The host matters
            // most for video/PDF (where there's no article chrome to read it
            // off) and for aggregators — "Hacker News" tells you nothing, but
            // "youtube.com" tells you exactly what you're about to open. Both
            // sit outside the content switch, so they persist across every
            // reader state.
            VStack(spacing: 1) {
                Text(item.sourceTitle)
                    .font(.custom("Charter", size: 11))
                    .kerning(1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let host = store.displayHost(for: item) {
                    Label(host, systemImage: "globe")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help("Source of this material: \(host)")
                }
            }

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

        case .video(let target):
            switch target {
            case .youTube(let id):
                VideoEmbedView(html: Self.youTubeEmbedHTML(id),
                               baseURL: URL(string: "https://jorviksoftware.cc"))
                    .background(Color.black)
            case .vimeo(let id):
                VideoEmbedView(html: Self.vimeoEmbedHTML(id),
                               baseURL: URL(string: "https://player.vimeo.com"))
                    .background(Color.black)
            case .native(let mediaURL):
                NativeVideoView(url: mediaURL)
            }

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
        // Video links play in-app, chrome-free, rather than opening a browser.
        if let video = Self.detectVideo(item.link) {
            state = .video(video)
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

    // MARK: - Video detection

    /// Classify a link as a playable video, or nil if it isn't one. Direct
    /// media files play natively; YouTube / Vimeo resolve to a chrome-free
    /// embed URL (autoplay, no surrounding page).
    static func detectVideo(_ url: URL) -> VideoTarget? {
        let host = url.host?.lowercased() ?? ""
        let ext = url.pathExtension.lowercased()

        if ["mp4", "m4v", "mov", "webm"].contains(ext) {
            return .native(url)
        }
        if host.contains("youtube.com") || host == "youtu.be" || host.hasSuffix(".youtu.be") {
            if let id = youTubeID(url) { return .youTube(id) }
        }
        if host.contains("vimeo.com") {
            if let id = vimeoID(url) { return .vimeo(id) }
        }
        return nil
    }

    /// Host page wrapping a YouTube `<iframe>`, loaded via
    /// `loadHTMLString(_, baseURL: jorviksoftware.cc)` so the player sees a
    /// legitimate **third-party** origin. Loading the bare `/embed/` URL as a
    /// top-level document gives "Error 153"; claiming youtube.com as the
    /// origin (a self-referential embed) gives "Error 152". A normal
    /// third-party origin is what a real embed has.
    private static func youTubeEmbedHTML(_ id: String) -> String {
        """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style></head>
        <body><iframe src="https://www.youtube.com/embed/\(id)?playsinline=1&autoplay=1&rel=0&origin=https://jorviksoftware.cc"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe></body></html>
        """
    }

    private static func vimeoEmbedHTML(_ id: String) -> String {
        """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style></head>
        <body><iframe src="https://player.vimeo.com/video/\(id)?autoplay=1"
        allow="autoplay; fullscreen; picture-in-picture" allowfullscreen></iframe></body></html>
        """
    }

    private static func youTubeID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("youtu.be") { return parts.first }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        // /embed/ID, /shorts/ID, /v/ID
        if let idx = parts.firstIndex(where: { ["embed", "shorts", "v"].contains($0) }),
           idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }

    private static func vimeoID(_ url: URL) -> String? {
        // vimeo.com/123456789 or player.vimeo.com/video/123456789
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.last(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
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

// MARK: - Embedded video (YouTube / Vimeo)

/// Loads a small host page containing the platform's `<iframe>` player, with
/// a `baseURL` matching the platform so the embed gets a valid origin. JS on
/// (the player needs it) and autoplay permitted; ephemeral data store.
struct VideoEmbedView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []   // allow autoplay
        let web = WKWebView(frame: .zero, configuration: config)
        // Restricted videos (age/region/embed-blocked) render YouTube's own
        // "Watch video on YouTube" link as target="_blank", which a WKWebView
        // would otherwise swallow. Route it into the same view so the full
        // watch page loads in-app and plays, instead of doing nothing.
        web.uiDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard !context.coordinator.loaded else { return }
        context.coordinator.loaded = true
        web.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKUIDelegate {
        var loaded = false

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

// MARK: - Native video

/// Basic native player for direct media files (`.mp4`, `.mov`, …). Just the
/// `AVPlayer` transport over a black backdrop — no page chrome. The player is
/// held in `@State` so it isn't recreated on every redraw, and paused when
/// the view goes away.
private struct NativeVideoView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .background(Color.black)
            .onAppear {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
    }
}
