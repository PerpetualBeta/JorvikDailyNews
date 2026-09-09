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
    /// Set once a load has been running long enough that silence reads as a
    /// hang. Eight seconds: the extractor's own fetch timeout is 10s, so this
    /// appears before the first thing that could fail does.
    @State private var slowToLoad = false
    private static let slowLoadNoticeNanoseconds: UInt64 = 8 * 1_000_000_000
    /// Whether the live-page fallback has drawn anything yet. Until it has, a
    /// cover sits over it, because the web view must be mounted to load and a
    /// mounted empty one looks exactly like the fault.
    @State private var liveDrew = false
    /// Whether the extracted article is on screen yet. Same reasoning as
    /// `liveDrew`: the web view has to be mounted to render, so it is covered
    /// until it has. There is no state in this reader that shows a blank pane.
    @State private var articleDrew = false

    enum ReaderState {
        case loading
        case ready(ArticleExtractor.Article)
        case pdf(URL)
        case video(VideoLink)
        case failed(Failure)
        /// Nothing could be shown: not the reader, not the original page.
        /// Carries what to tell the reader, because the alternative is the
        /// blank sheet this state exists to replace.
        case unavailable(Problem)
    }

    /// Why the reader fell through to the live page, kept as a type rather
    /// than a sentence.
    ///
    /// The two cases need opposite advice and the first version gave them the
    /// same. A page whose bytes never arrived has nothing to do with macOS,
    /// and telling somebody "that points at the part of macOS that draws web
    /// pages" when a slow server timed out is a confident wrong answer of
    /// exactly the kind this whole day was spent removing. Seen live on
    /// `spectrum.ieee.org`, which returns the same 469 KB in anywhere from
    /// 5.2s to 13.8s.
    struct Failure {
        /// The measurements, for the small print and for a bug report.
        let detail: String
        /// True when the article's own request never completed, so nothing was
        /// ever handed to a web view and macOS is not implicated.
        var neverArrived = false
    }

    /// What went wrong, in the reader's language and in mine.
    ///
    /// `headline` and `advice` are for the person looking at it. `technical`
    /// is the line that makes a bug report useful, shown small rather than
    /// hidden, because somebody who wants to report this should not have to
    /// turn on diagnostics first.
    struct Problem {
        let headline: String
        let advice: String
        let technical: String
        var canRetry = true
    }

    /// How a video link is played in-app: a YouTube/Vimeo player embedded
    /// chrome-free (as an `<iframe>` in a host page so the player gets a valid
    /// origin), or a native `AVPlayer` for a direct media file.
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
            // "Turning to the article…" on its own is indistinguishable from a
            // hang after a few seconds. Saying so is not a fix, but it is the
            // difference between waiting and wondering.
            VStack(spacing: 14) {
                ProgressView()
                Text("Turning to the article\u{2026}")
                    .font(.custom("Charter", size: 12))
                    .foregroundStyle(.secondary)
                if slowToLoad {
                    Text("This one is taking longer than usual.")
                        .font(.custom("Charter", size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: "loading-\(item.itemId)") {
                slowToLoad = false
                try? await Task.sleep(nanoseconds: Self.slowLoadNoticeNanoseconds)
                if !Task.isCancelled { slowToLoad = true }
            }

        case .ready(let article):
          ZStack {
            ReaderWebView(html: renderHTML(article), baseURL: item.link, onBlank: { detail in
                // Neither route rendered the extracted article. Rather than
                // leave a blank sheet, fall through to the same live page every
                // other failure falls through to, so this release cannot be
                // worse than the one before it.
                guard case .ready = state else { return }
                jdnLog("reader: nothing rendered the article — live page fallback")
                state = .failed(Failure(detail: detail))
            }, onDrew: { articleDrew = true })

            if !articleDrew {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Turning to the article\u{2026}")
                        .font(.custom("Charter", size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
          }
          .task(id: "drew-\(item.itemId)") { articleDrew = false }

        case .pdf(let url):
            PDFReader(url: url)

        case .video(let target):
            switch target {
            case .youTube(let id):
                VideoEmbedView(html: Self.youTubeEmbedHTML(id),
                               baseURL: URL(string: "https://jorviksoftware.cc"),
                               what: "YouTube \(id)",
                               link: item.link)
                    .background(Color.black)
            case .vimeo(let id):
                VideoEmbedView(html: Self.vimeoEmbedHTML(id),
                               baseURL: URL(string: "https://player.vimeo.com"),
                               what: "Vimeo \(id)",
                               link: item.link)
                    .background(Color.black)
            case .native(let mediaURL):
                NativeVideoView(url: mediaURL)
            }

        case .failed(let failure):
            // No clean reader view (link lists like HN, paywalls, SPA-rendered
            // pages). Rather than dead-ending the user out to a browser, render
            // the real page inline in a full web view. The header's "Open in
            // Browser" stays as the escape hatch for anyone who wants it.
            //
            // The live page used to be the end of the line, and it renders
            // through the same WebKit as everything else. When WebKit is not
            // rendering, this showed a blank sheet with no explanation, which
            // is the worst outcome the app can produce: the reader cannot tell
            // a broken article from a slow one from a broken app.
            // The live page has to be in the hierarchy to load at all, and an
            // empty web view IS the blank pane this whole chain exists to
            // prevent. So it loads underneath a cover that says what is
            // happening, and the cover lifts the moment it has drawn
            // something. Before this the reader showed white for up to 8.4
            // seconds, which is long enough for anyone to give up and click
            // away — as happened the first time it was tried.
            ZStack {
              LiveWebView(url: item.link, onBlank: {
                guard case .failed = state else { return }
                jdnLog("reader: the live page did not render either — giving up with an explanation")
                // The advice used to end "quitting and reopening Jorvik Daily
                // News clears it". It was written from the assumption that a
                // restart clears it, and on 2026-09-09 it did not: the app was
                // relaunched twice during a 21-minute spell and every article
                // still failed, in the installed release as well as the
                // development build. It cleared itself, roughly twenty minutes
                // later, with no restart involved. Telling somebody to do a
                // thing that will not work is worse than telling them nothing,
                // because they will conclude the app is lying to them.
                state = .unavailable(failure.neverArrived
                    ? Problem(
                        headline: "This article would not download",
                        advice: "The site did not answer in time, so there was "
                              + "nothing to read. That is the site being slow "
                              + "or unreachable rather than anything wrong on "
                              + "this Mac. Trying again often works, and so "
                              + "does opening it in your browser, which waits "
                              + "longer than the reader does.",
                        technical: failure.detail)
                    : Problem(
                        headline: "This article would not open",
                        advice: "The article was downloaded but nothing would "
                              + "display it, neither the reader nor the "
                              + "original page. That points at the part of "
                              + "macOS that draws web pages rather than at "
                              + "anything wrong with the article. Opening it in "
                              + "your browser will work. If every article does "
                              + "this, it usually comes right on its own after "
                              + "a few minutes. A restart is worth trying but "
                              + "may not help.",
                        technical: failure.detail))
              }, onDrew: { liveDrew = true })

              if !liveDrew {
                  VStack(spacing: 14) {
                      ProgressView()
                      Text("The reader could not lay this one out.")
                          .font(.custom("Charter", size: 14))
                      Text("Fetching the original page\u{2026}")
                          .font(.custom("Charter", size: 12))
                          .foregroundStyle(.secondary)
                  }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .background(Color(nsColor: .textBackgroundColor))
              }
            }
            .task(id: "live-\(item.itemId)") { liveDrew = false }

        case .unavailable(let problem):
            ReaderNotice(problem: problem,
                         link: item.link,
                         retry: { state = .loading; Task { await extract() } })
        }
    }

    /// How long the reader will wait before giving up and showing the real
    /// page. Longer than `ArticleExtractor`'s own 20s so that its timeout, and
    /// its better error message, normally win; this only catches an extraction
    /// that never returns at all.
    private static let readerDeadline: TimeInterval = 25

    private func extract() async {
        state = .loading
        jdnLog("reader: opening \(item.link.absoluteString)")
        // Fast path: an obvious .pdf link skips the HTML extractor entirely.
        if item.link.pathExtension.lowercased() == "pdf" {
            jdnLog("reader: .pdf extension — PDF view")
            state = .pdf(item.link)
            return
        }
        // Video links play in-app, chrome-free, rather than opening a browser.
        if let video = VideoLink.detect(item.link) {
            jdnLog("reader: video link — player view")
            state = .video(video)
            return
        }
        // A backstop deadline, independent of the extractor's own.
        //
        // `ArticleExtractor` already times out at 20s and every failure path
        // falls through to the live page, so in principle this can never fire.
        // A user report says otherwise: articles that sat on "Turning to the
        // article…" indefinitely while Open in Browser worked. That symptom can
        // only mean the extraction never returned at all, so the honest fix is
        // not to trust that it will. Whatever the cause turns out to be, the
        // reader now stops waiting and shows the real page instead.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.readerDeadline * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if case .loading = state {
                jdnLog("reader: BACKSTOP deadline at \(Self.readerDeadline)s — the extractor never returned; live page fallback")
                state = .failed(Failure(detail: "The reader took too long to open this article"))
            }
        }
        defer { deadline.cancel() }

        let extractor = ArticleExtractor()
        do {
            let article = try await extractor.extract(url: item.link)
            // Only if the backstop has not already moved us on.
            guard case .loading = state else {
                jdnLog("reader: extraction returned after the backstop had given up — leaving the live page")
                return
            }
            jdnLog("reader: reader view ready")
            state = .ready(article)
        } catch ArticleExtractor.ExtractionError.isPDF {
            // PDF without a .pdf extension — detected by content-type / magic.
            guard case .loading = state else { return }
            jdnLog("reader: detected a PDF by content — PDF view")
            state = .pdf(item.link)
        } catch {
            guard case .loading = state else { return }
            jdnLog("reader: extraction failed (\(error.localizedDescription)) — live page fallback")
            // Classified on the error type, not by reading the message. Only
            // `fetchFailed` means the bytes never arrived; every other case
            // means we had the page and could not make an article of it.
            let neverArrived: Bool
            if case ArticleExtractor.ExtractionError.fetchFailed = error {
                neverArrived = true
            } else {
                neverArrived = false
            }
            state = .failed(Failure(detail: error.localizedDescription,
                                    neverArrived: neverArrived))
        }
        jdnLog("reader: settled")
    }

    // MARK: - Video detection

    /// Classify a link as a playable video, or nil if it isn't one. Direct
    /// media files play natively; YouTube / Vimeo resolve to a chrome-free
    /// embed URL (autoplay, no surrounding page).
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
    /// Called when neither route produced a document, so the sheet can show the
    /// live page instead of nothing.
    /// Reports the measurements, not just the fact. "WebKit rendered nothing:
    /// the reader could not display this article" said the same thing twice and
    /// carried no numbers, which is no use in a bug report.
    let onBlank: (String) -> Void
    /// Called as soon as the article is actually on screen, so the caller can
    /// lift its cover. Without this the reader shows white for the whole grace
    /// period even when the document renders in 150 ms.
    var onDrew: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        // Registered up front because a scheme handler can only be attached to
        // a configuration before its web view exists. It serves nothing unless
        // the check below asks it to.
        config.setURLSchemeHandler(context.coordinator.handler,
                                   forURLScheme: ReaderBytesHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // SwiftUI calls this on any state change in the sheet, and reloading
        // the same document throws away the reader's scroll position — and,
        // worse, would restart the check below against a page that had already
        // passed it.
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        context.coordinator.show(html, baseURL: baseURL, in: web,
                                 onBlank: onBlank, onDrew: onDrew)
    }

    /// Renders the reader document, and notices if WebKit quietly declines to.
    ///
    /// `loadHTMLString` is the same API the extractor uses, and on the
    /// reporter's macOS 27.0 beta it has never once produced a document: five
    /// logs, eleven articles, four sizes, blocking on and off, and the DOM is
    /// the 39-character empty skeleton every time with no delegate callback of
    /// any kind. Fixing extraction without fixing this would have handed him a
    /// blank white sheet in place of today's live-page fallback, which is worse
    /// than the bug he reported.
    ///
    /// So the reader stops assuming the render worked and checks. If the
    /// document never arrives it re-serves the identical bytes over a private
    /// scheme, which is a *real* resource load and does not go near the
    /// substitute-data path that is failing. On a healthy Mac the check passes
    /// on the first poll and nothing else happens.
    ///
    /// This is a guard against a failure nobody has observed yet — the
    /// reporter has never reached a reader view to find out. It is here because
    /// the cost is one timer and the cost of being wrong is release ten.
    @MainActor
    final class Coordinator {
        let handler = ReaderBytesHandler()
        var shown: String?
        private var check: Task<Void, Never>?

        /// How long to let `loadHTMLString` render before checking on it.
        /// Measured on macOS 26, a reader document commits and parses in about
        /// 150 ms, so this is eight times the observed cost.
        private static let grace: TimeInterval = 1.2
        private static let pollInterval: UInt64 = 100_000_000

        func show(_ html: String, baseURL: URL?, in web: WKWebView,
                  onBlank: @escaping (String) -> Void, onDrew: @escaping () -> Void) {
            check?.cancel()
            // The same bytes either way, so the two routes cannot render
            // differently. The `<base href>` matters only to the fallback,
            // whose document is served from the private scheme and would
            // otherwise resolve relative links against that.
            let document = baseURL.map { ArticleExtractor.withBaseHref(html, $0) } ?? html
            handler.document = document
            web.loadHTMLString(html, baseURL: baseURL)
            check = Task { @MainActor [weak web] in
                let probe = "document.documentElement.outerHTML.length"
                // A `WKWebView` starts out holding about 39 characters of empty
                // skeleton, and that skeleton reports `readyState` as
                // `complete`, so length is the only honest test.
                let floor = max(200, html.count / 10)
                var chars = 0
                let started = Date()
                // Poll rather than sleep the whole grace and ask once. A
                // document renders in about 150 ms, so asking once at 1.2s
                // held the reader on a blank pane eight times longer than it
                // needed to be.
                while Date().timeIntervalSince(started) < Self.grace {
                    try? await Task.sleep(nanoseconds: Self.pollInterval)
                    guard !Task.isCancelled, let web else { return }
                    chars = ReaderFailureSimulation.isOn ? 39
                        : (try? await web.evaluateJavaScript(probe)) as? Int ?? 0
                    if chars >= floor { onDrew(); return }
                }
                guard !Task.isCancelled, let web else { return }
                jdnLog("reader: loadHTMLString produced only \(chars) chars of"
                       + " \(html.count) after \(Self.grace)s — re-serving over"
                       + " \(ReaderBytesHandler.scheme):")
                web.load(URLRequest(url: ReaderBytesHandler.documentURL))
                // And check that too, because a fallback nobody can verify is
                // only a second way to show a blank sheet.
                try? await Task.sleep(nanoseconds: UInt64(Self.grace * 1_000_000_000))
                guard !Task.isCancelled else { return }
                var after = 0
                let retried = Date()
                while Date().timeIntervalSince(retried) < Self.grace {
                    try? await Task.sleep(nanoseconds: Self.pollInterval)
                    guard !Task.isCancelled else { return }
                    after = ReaderFailureSimulation.isOn ? 39
                        : (try? await web.evaluateJavaScript(probe)) as? Int ?? 0
                    if after >= floor {
                        jdnLog("reader: \(ReaderBytesHandler.scheme): rendered it — \(after) chars")
                        onDrew()
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                jdnLog("reader: \(ReaderBytesHandler.scheme): produced only \(after) chars too")
                onBlank("article \(html.count) chars; loadHTMLString drew \(chars), "
                        + "\(ReaderBytesHandler.scheme) drew \(after), floor \(floor)")
            }
        }
    }
}

/// Serves the reader's own document, from memory, over a private scheme.
///
/// Separate from `ArticleExtractor`'s `BytesSchemeHandler` because that one is
/// built per extraction around fixed bytes; this one outlives a sheet and its
/// document is replaced whenever the reader renders a new article.
@MainActor
final class ReaderBytesHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "jdn-reader"
    static let documentURL = URL(string: "\(scheme)://read/article")!

    var document: String = ""
    /// A task WebKit has stopped must never be told anything again, or the
    /// process traps.
    private var stopped = Set<ObjectIdentifier>()

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated { serve(urlSchemeTask) }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated { _ = stopped.insert(ObjectIdentifier(urlSchemeTask)) }
    }

    private func serve(_ task: any WKURLSchemeTask) {
        guard !stopped.contains(ObjectIdentifier(task)) else { return }
        guard task.request.url == Self.documentURL, let data = document.data(using: .utf8) else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let response = URLResponse(url: Self.documentURL, mimeType: "text/html",
                                   expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
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
    /// Called when the live page rendered nothing at all. This view is the end
    /// of every fallback chain in the reader, and it draws through the same
    /// WebKit as the routes that already failed, so it is the one place a
    /// blank sheet could still reach the reader with no explanation.
    var onBlank: () -> Void = {}
    /// Called once the live page has actually drawn something. The caller keeps
    /// a cover over this view until then, because the page has to be in the
    /// hierarchy to load at all and an empty web view is exactly the blank
    /// pane the whole chain exists to prevent.
    var onDrew: () -> Void = {}

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
            context.coordinator.watch(web, onBlank: onBlank, onDrew: onDrew)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var check: Task<Void, Never>?

        /// A real page over the network needs far longer than the reader's own
        /// document does. This is generous on purpose: reporting "it did not
        /// render" about a page that was merely slow would be worse than the
        /// blank sheet, because it would send the reader away from a page that
        /// was about to appear.
        private static let grace: TimeInterval = 6

        func watch(_ web: WKWebView, onBlank: @escaping () -> Void,
                   onDrew: @escaping () -> Void) {
            check?.cancel()
            // Poll rather than wait out the whole grace period. A page that
            // draws in 300 ms should be revealed in 300 ms; only a page that
            // draws nothing should cost the full wait. Sleeping first and
            // asking once meant every fallback took the worst case, and the
            // reader saw a blank pane for all of it.
            check = Task { @MainActor [weak web] in
                let started = Date()
                let probe = "document.documentElement.outerHTML.length"
                while Date().timeIntervalSince(started) < Self.grace {
                    try? await Task.sleep(nanoseconds: Self.pollInterval)
                    guard !Task.isCancelled, let web else { return }
                    let chars = ReaderFailureSimulation.isOn ? Self.emptyDocumentChars
                        : (try? await web.evaluateJavaScript(probe)) as? Int ?? 0
                    // 39 characters is the empty skeleton a web view starts
                    // with, and it reports `readyState` as `complete`, so
                    // length is the only honest test. A real page is thousands.
                    if chars > Self.emptyDocumentChars {
                        jdnLog("reader: live page rendered \(chars) chars")
                        onDrew()
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                jdnLog("reader: live page produced nothing after \(Int(Self.grace))s")
                onBlank()
            }
        }

        private static let pollInterval: UInt64 = 200_000_000

        private static let emptyDocumentChars =
            "<html><head></head><body></body></html>".count
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
    @State private var state: Load = .starting

    /// A 7.4 MB report at 176 KB/s is forty-two seconds of waiting, and
    /// "Loading PDF…" for forty-two seconds is indistinguishable from a hang.
    /// The reader asked "how big is this PDF, it's taking ages?" — a question
    /// the app was holding the answer to and not saying.
    enum Load {
        case starting
        case downloading(received: Int64, total: Int64)
        case ready
        case failed(String)
    }

    var body: some View {
        ZStack {
            PDFKitView(url: url,
                       onProgress: { received, total in
                           if case .ready = state { return }
                           state = .downloading(received: received, total: total)
                       },
                       onReady: { state = .ready },
                       onFailure: { state = .failed($0) })

            switch state {
            case .ready:
                EmptyView()

            case .failed(let why):
                // Previously this was a white page: `defer { onLoaded() }`
                // lifted the cover whether or not a document had arrived, so a
                // failure revealed an empty PDFView and said nothing.
                ReaderNotice(problem: ReaderView.Problem(
                    headline: "This PDF would not open",
                    advice: "The file could not be downloaded or could not be "
                          + "read as a PDF. Opening it in your browser is the "
                          + "quickest way to see it, and will also show you "
                          + "whether the file itself is the problem.",
                    technical: why), link: url, retry: { state = .starting })

            case .starting, .downloading:
                VStack(spacing: 14) {
                    // Three states, not two. A server that declares no length
                    // gets a spinner and a running byte count rather than the
                    // bare "Loading PDF…", which is what happened on a 7.4 MB
                    // report that took 163 seconds: `Content-Length` was
                    // absent on that request, so the determinate branch never
                    // fired and the reader got no sign of progress for nearly
                    // three minutes.
                    if case .downloading(let got, let total) = state, total > 0 {
                        ProgressView(value: Double(got), total: Double(total))
                            .frame(width: 220)
                        Text("\(Self.mb(got)) of \(Self.mb(total))")
                            .font(.custom("Charter", size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if case .downloading(let got, _) = state {
                        ProgressView()
                        Text("\(Self.mb(got)) downloaded")
                            .font(.custom("Charter", size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("the server did not say how big this is")
                            .font(.custom("Charter", size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        ProgressView()
                        Text("Loading PDF\u{2026}")
                            .font(.custom("Charter", size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

extension PDFView {
    /// Scroll to the top-left of the first page.
    func goToTop() {
        guard let first = document?.page(at: 0) else { return }
        let box = first.bounds(for: .cropBox)
        // PDF coordinates run bottom-up, so the top of the page is maxY.
        go(to: CGRect(x: box.minX, y: box.maxY - 1, width: 1, height: 1), on: first)
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL
    var onProgress: (Int64, Int64) -> Void = { _, _ in }
    var onReady: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }

    /// Long enough for a large report on a slow line — the one that prompted
    /// this took 42 seconds for 7.4 MB — and short enough that a dead host
    /// does not hold the reader indefinitely. The request carried no timeout
    /// at all before, so it inherited URLSession's 60-second default and gave
    /// no sign of which it was doing.
    private static let timeout: TimeInterval = 120
    /// How often to publish progress. Five times a second is smooth to watch
    /// and costs nothing against a download measured in minutes.
    ///
    /// `nonisolated` because it is read from the detached download task. The
    /// view is main-actor isolated, so a plain `static let` on it is too, and
    /// Swift 6 makes that an error rather than a warning.
    nonisolated static let reportEvery: TimeInterval = 0.2

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .textBackgroundColor
        load(into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    private func load(into view: PDFView) {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let url = self.url
        let onProgress = self.onProgress
        let onReady = self.onReady
        let onFailure = self.onFailure

        // Downloaded OFF the main actor, with only the progress reports and the
        // finished document hopping onto it.
        //
        // The first version ran the whole `for try await byte in stream` loop
        // on the main actor. Appending 7.4 million bytes measures at 0.21s, so
        // the append is not the problem, but seven million suspension points
        // interleaved with the interface is not something to ship on the
        // strength of one benchmark that did not include them.
        Task.detached {
            let started = Date()
            do {
                // Streamed rather than fetched whole, so the size can be shown
                // and the wait stops looking like a hang. `data(for:)` reports
                // nothing until it has everything.
                let (stream, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    jdnLog("pdf: \(url.host ?? "?") returned HTTP \(http.statusCode)")
                    await MainActor.run { onFailure("HTTP \(http.statusCode)") }
                    return
                }
                let total = response.expectedContentLength
                jdnLog("pdf: downloading \(url.lastPathComponent) — "
                       + (total > 0 ? "\(total) bytes" : "size not declared"))

                var data = Data()
                if total > 0 { data.reserveCapacity(Int(total)) }
                var lastReport = Date()
                for try await byte in stream {
                    data.append(byte)
                    // Report on a timer, not per byte: a 7.4 MB file is 7.4
                    // million iterations and a state write on each would cost
                    // far more than the download.
                    if Date().timeIntervalSince(lastReport) > Self.reportEvery {
                        lastReport = Date()
                        let got = Int64(data.count)
                        await MainActor.run { onProgress(got, total) }
                    }
                }

                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                guard let document = PDFDocument(data: data) else {
                    jdnLog("pdf: \(data.count) bytes arrived in \(elapsed)s but PDFKit "
                           + "would not read them as a PDF")
                    let n = data.count
                    await MainActor.run { onFailure("\(n) bytes downloaded, not readable as a PDF") }
                    return
                }
                let bytes = data.count
                await MainActor.run {
                    view.document = document
                    // Open at the top of page one.
                    //
                    // `PDFView` does not, and setting `document` leaves the
                    // scroll position somewhere in the first page, so every
                    // document opened part-way down. `goToFirstPage` selects
                    // the page without moving to its top edge, so the
                    // destination is built explicitly at the top-left of the
                    // crop box. `autoScales` recomputes the zoom after the
                    // document is set, which moves the origin again, so this
                    // is done once more on the next run-loop turn.
                    view.goToTop()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        view.goToTop()
                    }
                    jdnLog("pdf: \(document.pageCount) page(s), \(bytes) bytes in \(elapsed)s")
                    onReady()
                }
            } catch {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                jdnLog("pdf: FAILED after \(elapsed)s — \(error.localizedDescription)")
                let why = error.localizedDescription
                await MainActor.run { onFailure(why) }
            }
        }
    }
}

// MARK: - Embedded video (YouTube / Vimeo)

/// Loads a small host page containing the platform's `<iframe>` player, with
/// a `baseURL` matching the platform so the embed gets a valid origin. JS on
/// (the player needs it) and autoplay permitted; ephemeral data store.
struct VideoEmbedView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    /// What was detected, for the log. A wrong or empty video id produces the
    /// same black rectangle as a working one, so the id has to be recorded or
    /// a detection bug is indistinguishable from a player failure.
    var what: String = "video"
    /// The original link, so a failure can offer the way through.
    var link: URL?

    func makeNSView(context: Context) -> NSView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []   // allow autoplay
        let web = WKWebView(frame: .zero, configuration: config)
        // Restricted videos (age/region/embed-blocked) render YouTube's own
        // "Watch video on YouTube" link as target="_blank", which a WKWebView
        // would otherwise swallow. Route it into the same view so the full
        // watch page loads in-app and plays, instead of doing nothing.
        web.uiDelegate = context.coordinator
        context.coordinator.web = web
        return context.coordinator.host(web)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard !context.coordinator.loaded, context.coordinator.web != nil else { return }
        context.coordinator.loaded = true
        jdnLog("video: loading \(what) — \(html.count) char host page")
        context.coordinator.show(html, baseURL: baseURL, what: what, link: link)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Watches for the failure this path could not previously report.
    ///
    /// The host page is a 511-character `<iframe>` wrapper handed to
    /// `loadHTMLString`, which is the API measured dead on one reporter's
    /// macOS 27 beta above about 8 KB — and this path had no blank detection,
    /// no logging and no failure state, so a video that would not play was a
    /// white rectangle and complete silence. That is the fourth place in this
    /// app where a `defer` or a missing check turned a failure into a blank
    /// pane; the reader, the live page and the PDF view were the others.
    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        var loaded = false
        weak var web: WKWebView?
        private var container: NSView?
        private var check: Task<Void, Never>?

        /// A player needs longer than a document: the host page has to load,
        /// then the iframe, then the player's own scripts.
        private static let grace: TimeInterval = 8
        private static let emptyDocumentChars =
            "<html><head></head><body></body></html>".count

        func host(_ web: WKWebView) -> NSView {
            let container = NSView()
            web.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(web)
            NSLayoutConstraint.activate([
                web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                web.topAnchor.constraint(equalTo: container.topAnchor),
                web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            self.container = container
            return container
        }

        func show(_ html: String, baseURL: URL?, what: String, link: URL?) {
            guard let web else { return }
            web.loadHTMLString(html, baseURL: baseURL)
            check?.cancel()
            check = Task { @MainActor [weak self, weak web] in
                try? await Task.sleep(nanoseconds: UInt64(Self.grace * Double(NSEC_PER_SEC)))
                guard !Task.isCancelled, let self, let web else { return }
                let probe = "document.documentElement.outerHTML.length"
                let chars = (try? await web.evaluateJavaScript(probe)) as? Int ?? 0
                guard chars <= Self.emptyDocumentChars else {
                    jdnLog("video: \(what) host page rendered \(chars) chars")
                    return
                }
                jdnLog("video: \(what) drew nothing after \(Int(Self.grace))s — "
                       + "the host page never rendered")
                self.showFailure(link: link)
            }
        }

        /// Replace the empty web view with something that explains itself.
        /// Done in AppKit rather than by pushing a new SwiftUI state, because
        /// this view is a leaf in the reader's `switch` and does not own it.
        private func showFailure(link: URL?) {
            guard let container else { return }
            web?.removeFromSuperview()
            let label = NSTextField(labelWithString:
                "This video would not play.\n\nThe player did not load. "
                + "Opening it in your browser will work.")
            label.alignment = .center
            label.maximumNumberOfLines = 0
            label.font = NSFont(name: "Charter", size: 14) ?? .systemFont(ofSize: 14)
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false

            let button = NSButton(title: "Open in Browser", target: self,
                                  action: #selector(openInBrowser))
            button.translatesAutoresizingMaskIntoConstraints = false
            self.failureLink = link

            let stack = NSStackView(views: [label, button])
            stack.orientation = .vertical
            stack.spacing = 18
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            ])
        }

        private var failureLink: URL?

        @objc private func openInBrowser() {
            guard let failureLink else { return }
            NSWorkspace.shared.open(failureLink)
        }

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

// MARK: - When nothing can be shown

/// The reader's last resort, and the one it never had.
///
/// Every other state in `ReaderState` draws something. This one exists for the
/// case where none of them can: extraction produced nothing, the reader's own
/// document did not render, the private-scheme copy did not render, and the
/// live page did not render either. Before this, that combination showed an
/// empty white pane and said nothing, which cannot be told apart from a slow
/// load, a broken article, or a broken app.
///
/// It says three things, in the order a person needs them: that it failed,
/// what to do instead, and what actually happened. The last of those is small
/// and selectable rather than hidden behind a diagnostics switch, because the
/// people most likely to report a fault are the ones least likely to have
/// turned logging on first.
struct ReaderNotice: View {
    let problem: ReaderView.Problem
    let link: URL
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.page.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)

            Text(problem.headline)
                .font(.custom("Charter", size: 20))

            Text(problem.advice.noOrphan)
                .font(.custom("Charter", size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: Self.proseWidth)

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .keyboardShortcut(.defaultAction)

                if problem.canRetry {
                    Button("Try Again", action: retry)
                }
            }
            .padding(.top, 2)

            Text(problem.technical)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: Self.technicalWidth)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The reader's own column is 680 points. This is narrower, because a
    /// centred paragraph of apology reads worse the wider it gets.
    private static let proseWidth: CGFloat = 420
    /// The measurements are monospaced and comma-separated, so they need more
    /// room than the prose does. At this width the usual line fits whole
    /// instead of dropping a two-word tail onto a second line.
    private static let technicalWidth: CGFloat = 520
}

extension String {
    /// Ties the last two words together so a paragraph cannot end with a
    /// single word on its own line.
    ///
    /// Rewording to fit is not a fix: the orphan comes back at the next window
    /// width, the next font size, or the next edit to the sentence.
    ///
    /// The obvious tool is U+00A0, and in Charter it is wrong. Measured at
    /// 14pt: Charter's normal space advances **3.89pt** and its no-break space
    /// advances **7.79pt**, exactly double, so the guard put a visible double
    /// space in the middle of the sentence. Helvetica has them equal, which is
    /// why this is easy to ship without noticing.
    ///
    /// So the space stays a normal space and the *break* is suppressed instead,
    /// with a WORD JOINER either side of it. UAX #14 rule LB11 prohibits a
    /// break before or after U+2060, which removes the opportunity at that
    /// space without touching the glyph. Both joiners are needed: one before
    /// the space alone changes nothing, measured.
    var noOrphan: String {
        guard let gap = range(of: " ", options: .backwards) else { return self }
        return replacingCharacters(in: gap, with: "\u{2060} \u{2060}")
    }
}

/// Forces every render route in the reader to report that it drew nothing.
///
/// The notice this reveals exists for a state that cannot be summoned: WebKit
/// stops rendering, for reasons still unknown, and recovers on its own. It did
/// exactly that on 2026-09-09, twenty minutes after the fault appeared and
/// before the fix for it could be tried, which is how an error screen ships
/// having never once been looked at.
///
///     defaults write cc.jorviksoftware.JorvikDailyNews simulateBlankReader -bool YES
///
/// `defaults delete` the key to put it back. Off unless explicitly set to
/// true, which is why this reads the object rather than calling `bool(forKey:)`
/// — that answers false for a key that was never set, and would ship the
/// feature on for nobody and off for everybody if the sense were reversed.
enum ReaderFailureSimulation {
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: "simulateBlankReader") as? Bool ?? false
    }
}
