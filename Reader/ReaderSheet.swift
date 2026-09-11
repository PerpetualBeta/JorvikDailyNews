import SwiftUI
import WebKit
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
    /// Whether the video player reported that it never rendered.
    @State private var videoFailed = false

    /// Which renderer to use, so the two can be compared on the same article
    /// without a rebuild. Anything other than "webkit" means native.
    static var rendererPreference: String {
        UserDefaults.standard.string(forKey: "readerRenderer") ?? "native"
    }

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
        /// True when the page downloaded and simply is not an article — a
        /// product homepage, a picture page, a link. Telling somebody the
        /// reader could not lay it out is technically right and useless; what
        /// they need to know is that there was never an article to lay out.
        var notAnArticle = false
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

    /// A player, and the notice if it does not load.
    ///
    /// The failure state was first built in AppKit inside `VideoEmbedView`,
    /// on the reasoning that the view is a leaf in this `switch` and does not
    /// own the reader's state. That was true and it was still the wrong call:
    /// a hand-rolled `NSStackView` clipped its own label on both sides and
    /// lost its button, because an `NSTextField` with `maximumNumberOfLines`
    /// set and no `preferredMaxLayoutWidth` lays out as one long line. The
    /// reader already knows how to show a notice, and the pattern for a leaf
    /// reporting upward already exists: `LiveWebView.onBlank`.
    @ViewBuilder
    private func player(_ html: String, base: String, what: String) -> some View {
        ZStack {
            Color.black
            if videoFailed {
                ReaderNotice(problem: Problem(
                    headline: "This video would not play",
                    advice: "The player did not load. That is usually the part "
                          + "of macOS that draws web pages rather than the video "
                          + "itself, so opening it in your browser will work.",
                    technical: what), link: item.link,
                    retry: { videoFailed = false })
            } else {
                VideoEmbedView(html: html,
                               baseURL: URL(string: base),
                               what: what,
                               onFailure: { videoFailed = true })
            }
        }
        .task(id: "video-\(item.itemId)") { videoFailed = false }
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
          // The native renderer where the blocks exist, WebKit where they do
          // not — a WebKit rung produces an article without them.
          //
          // Native is the default because `loadHTMLString` renders nothing at
          // all, intermittently and with no error, on both machines this app
          // has been tested on. `readerRenderer` forces the old path for a
          // comparison:
          //
          //     defaults write cc.jorviksoftware.JorvikDailyNews readerRenderer webkit
          //
          if let blocks = article.blocks?.numbered(), !blocks.isEmpty,
             Self.rendererPreference != "webkit" {
              NativeReaderView(article: article,
                               blocks: blocks,
                               sourceTitle: item.sourceTitle,
                               // Where the page actually came from, so a
                               // relative link resolves against the article's
                               // own address rather than the feed's version of
                               // it. They differ whenever the link redirects.
                               baseURL: article.resolvedURL ?? item.link,
                               // The paper's own hero. Most sites keep their
                               // lede photograph outside the <article> element,
                               // so Readability drops it and the reader opened
                               // with nothing while the card had the picture.
                               hero: item.imageURL)
                  .task(id: "native-\(item.itemId)") {
                      jdnLog("reader: drawn natively — \(blocks.count) block(s), no web view")
                  }
          } else {
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
          }

        case .pdf(let url):
            // A `.pdf` path that serves HTML goes back through extraction. The
            // routing below trusts the extension, which is fine as a fast path
            // and wrong as a verdict — GitHub's `…/blob/…/report.pdf` is a web
            // page that displays a PDF, and the file is elsewhere.
            PDFReader(url: url, onNotAPDF: {
                jdnLog("reader: .pdf path served a web page — re-running extraction")
                state = .loading
                Task { await extract(trustingExtension: false) }
            })

        case .video(let target):
            switch target {
            case .youTube(let id):
                player(Self.youTubeEmbedHTML(id),
                       base: "https://jorviksoftware.cc",
                       what: "YouTube \(id)")
            case .vimeo(let id):
                player(Self.vimeoEmbedHTML(id),
                       base: "https://player.vimeo.com",
                       what: "Vimeo \(id)")
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
                if failure.notAnArticle {
                    state = .unavailable(Problem(
                        headline: "There is no article on this page",
                        advice: "The link goes to a page rather than a story — "
                              + "a product site, a picture, or a video, say — so "
                              + "there was nothing for the reader to lay out. "
                              + "The page itself could not be shown either, so "
                              + "your browser is the way to see it.",
                        technical: failure.detail))
                    return
                }
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
              // The web view had no frame of its own, so as a ZStack child it
              // took its intrinsic size while the cover filled the pane. A
              // WKWebView has almost no intrinsic size, and a collapsed one
              // lays out almost nothing: measured against the same page at
              // 1100x800, a 0x0 view reported 272 characters of laid-out text
              // instead of 2,873, and nothing at all for the first few
              // seconds. It would also have been useless once revealed.
              .frame(maxWidth: .infinity, maxHeight: .infinity)

              if !liveDrew {
                  LivePageCover(host: item.link.host ?? "the original page",
                                link: item.link)
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

    /// - Parameter trustingExtension: false after a `.pdf` path turned out to
    ///   serve HTML, so the fast path is skipped and the same link is not sent
    ///   straight back to the PDF viewer it just came from. Without this the
    ///   two would hand the link to each other for ever.
    private func extract(trustingExtension: Bool = true) async {
        state = .loading
        jdnLog("reader: opening \(item.link.absoluteString)")
        // Fast path: an obvious .pdf link skips the HTML extractor entirely.
        if trustingExtension, item.link.pathExtension.lowercased() == "pdf" {
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
            var neverArrived = false
            var notAnArticle = false
            switch error {
            case ArticleExtractor.ExtractionError.fetchFailed:
                neverArrived = true
            case ArticleExtractor.ExtractionError.tooShort,
                 ArticleExtractor.ExtractionError.noArticle:
                // The page came down fine and there is no article on it: a
                // product homepage, a picture page, a Show HN link. Showing
                // the page itself is the right answer, and if that fails the
                // reader deserves to be told which of the two things happened.
                notAnArticle = true
            default:
                break
            }
            state = .failed(Failure(detail: error.localizedDescription,
                                    neverArrived: neverArrived,
                                    notAnArticle: notAnArticle))
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
        // Refuses everything after the first load. See the delegate.
        web.navigationDelegate = context.coordinator
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
    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler = ReaderBytesHandler()
        var shown: String?
        private var check: Task<Void, Never>?

        /// The reader pane renders one extracted document and must never leave
        /// it.
        ///
        /// Scripting is already off, which stops `location =` and a submitted
        /// form. It does not stop `<meta http-equiv="refresh" content="0;
        /// url=…">`, which WebKit honours with no script involved, so an
        /// article could replace the reader's own pane with any page it liked
        /// — a convincing place to put a login form, since the sheet carries
        /// the app's chrome and the reader has no address bar to check.
        ///
        /// Nothing legitimate navigates here: the document is loaded once by
        /// `show(_:baseURL:in:)`, its links are drawn by the native renderer,
        /// and a click on one goes to the browser. So everything except that
        /// first load is refused, and any attempt is logged rather than
        /// silently dropped.
        func webView(_ web: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The initial load. `loadHTMLString` presents as `.other` with no
            // originating frame, and the reader's own scheme serves the same
            // document by another route.
            let target = action.request.url
            let isInitial = action.navigationType == .other
                && (target == nil
                    || target?.scheme == ReaderBytesHandler.scheme
                    || target?.absoluteString == "about:blank")
            guard !isInitial else { return decisionHandler(.allow) }
            jdnLog("reader: refused a navigation the article asked for — "
                   + "\(target?.absoluteString.prefix(120) ?? "(no url)") "
                   + "(type \(action.navigationType.rawValue))")
            decisionHandler(.cancel)
        }

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
        ///
        /// A backstop only. The real test is `isLoading`, below: a page that
        /// is still arriving has not failed at anything, and no fixed deadline
        /// can tell a slow server from a broken page.
        ///
        /// `adam.math.hhu.de` measured: the Lean Game Server sends 1,480 bytes
        /// of shell and then a **6,114,882-byte** JavaScript bundle from a
        /// server running at about 175 KB/s. `isLoading` stays true for **45
        /// seconds**, and React paints one second after it goes false. Any
        /// deadline short enough to feel responsive would have called that
        /// page broken while it was busily working.
        ///
        /// So this exists only so a page that loads for ever cannot hold the
        /// spinner for ever.
        private static let hardCap: TimeInterval = 75

        /// How long to wait for the navigation to commit at all.
        ///
        /// Separate from everything below it, because a document that has not
        /// arrived is a different fact from a document that has not painted.
        ///
        /// `outerHTML` stuck at 39 characters is the empty skeleton a web view
        /// starts with, and on this machine it is the signature of the WebKit
        /// fault: `policy=yes provisional=no commit=no`, the policy delegate
        /// answering and the provisional load never beginning. When that
        /// happens `isLoading` stays true for ever, so the wait ran the full
        /// 75 seconds and the reader sat in front of a counter for a fault the
        /// app could see in one second.
        ///
        /// Twelve seconds because that is `ArticleExtractor.fetchTimeout`, and
        /// a page whose first byte has not arrived in the time the fetcher
        /// would have given up is not merely slow. The document arrives early
        /// even on genuinely slow pages — adam.math.hhu.de had its 1,461
        /// characters at 0.9s and then spent 45 seconds on subresources — so
        /// this measures the one thing that is quick on every page that works.
        private static let commitDeadline: TimeInterval = 12

        /// How long to keep asking after the page has stopped loading.
        ///
        /// A JavaScript application paints some time after its last byte
        /// arrives — one second, on the page above. This is the only window
        /// where "drew nothing" is real evidence of failure, because before it
        /// the page had not finished arriving.
        private static let settle: TimeInterval = 5

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
                // When the page stopped loading, or nil while it still is.
                var stoppedLoading: Date?
                while Date().timeIntervalSince(started) < Self.hardCap {
                    try? await Task.sleep(nanoseconds: Self.pollInterval)
                    guard !Task.isCancelled, let web else { return }
                    let drawn = ReaderFailureSimulation.isOn ? Drawn.nothing
                        : await Self.measure(web)
                    if drawn.hasDrawn {
                        let waited = String(format: "%.1f", Date().timeIntervalSince(started))
                        jdnLog("reader: live page drew \(drawn.text) char(s) of text and "
                               + "\(drawn.media) media element(s) after \(waited)s")
                        onDrew()
                        return
                    }
                    // Nothing committed. Not slow — not started.
                    if !drawn.hasDocument,
                       Date().timeIntervalSince(started) >= Self.commitDeadline {
                        let waited = String(format: "%.1f", Date().timeIntervalSince(started))
                        jdnLog("reader: live page never began — still \(drawn.markup) chars "
                               + "of empty document after \(waited)s, so waiting longer "
                               + "cannot help; \(ArticleExtractor.webKitVerdict)")
                        onBlank()
                        return
                    }
                    // Still arriving. Nothing has failed, so nothing is
                    // reported — a slow server is not a broken page, and
                    // `estimatedProgress` cannot tell us how far along it is
                    // because it tracks the document and not the megabytes of
                    // script the document asks for afterwards.
                    if ReaderFailureSimulation.isOn || !web.isLoading {
                        if stoppedLoading == nil { stoppedLoading = Date() }
                    } else {
                        stoppedLoading = nil
                    }
                    guard let stoppedLoading,
                          Date().timeIntervalSince(stoppedLoading) >= Self.settle
                    else { continue }
                    Self.finish(drawn, after: started, why: "finished loading",
                                onBlank: onBlank, onDrew: onDrew)
                    return
                }
                guard !Task.isCancelled, let web else { return }
                Self.finish(await Self.measure(web), after: started,
                            why: "was still loading", onBlank: onBlank, onDrew: onDrew)
            }
        }

        /// The end of the wait: reveal, or report a blank pane.
        ///
        /// Never reports failure while a document exists. On 10 September 2026
        /// the layout probe returned **zero for every live page** inside the
        /// app while returning 2,873 characters for the same page in a bare
        /// harness, so two pages that were rendering perfectly well were told
        /// they had not rendered. Why the app's web view reports nothing is
        /// not yet known — it loads underneath an opaque cover, which is the
        /// obvious suspect and not yet the proven one.
        ///
        /// Until it is known, the asymmetry decides the behaviour. Revealing a
        /// page that turns out to be blank costs the reader a blank pane they
        /// can close. Claiming a page failed when it did not sends them away
        /// from an article that was there. So a document present but unmeasured
        /// is revealed, and only an empty document is called a failure.
        @MainActor
        private static func finish(_ drawn: Drawn, after started: Date, why: String,
                                   onBlank: @escaping () -> Void,
                                   onDrew: @escaping () -> Void) {
            let waited = String(format: "%.1f", Date().timeIntervalSince(started))
            guard drawn.hasDocument else {
                jdnLog("reader: live page held nothing at all after \(waited)s "
                       + "(it \(why)) — reporting a blank page; "
                       + ArticleExtractor.webKitVerdict)
                onBlank()
                return
            }
            jdnLog("reader: live page never reported any laid-out content after "
                   + "\(waited)s (it \(why)) — text \(drawn.text), media \(drawn.media), "
                   + "document \(drawn.markup) chars; showing it rather than claiming "
                   + "it failed")
            onDrew()
        }

        /// What the page has actually put on screen.
        ///
        /// The old probe read `document.documentElement.outerHTML.length` and
        /// revealed the page as soon as that passed 39 characters, the length
        /// of the empty skeleton a web view starts with. That measures the
        /// markup the server sent, which is not the same thing at all.
        ///
        /// `adam.math.hhu.de` is the case that showed it. The server sends
        /// **1,480 bytes** — a `<div id="root">` and a `<noscript>` — and
        /// builds the whole page in React afterwards. 1,461 characters sailed
        /// past the threshold, the cover lifted at once, and the reader
        /// watched a white rectangle for as long as the bundle took to boot.
        ///
        /// So this asks what has been laid out instead. `innerText` reports
        /// rendered text only, so an un-booted app scores zero and a
        /// `<noscript>` block does not count — which is exactly right, because
        /// the reader cannot see it either.
        ///
        /// Media is counted separately because a page can legitimately be one
        /// photograph and no prose, and text alone would call that blank for
        /// ever.
        private struct Drawn {
            let text: Int
            let media: Int
            /// Length of the whole document's markup. Needs no layout, which
            /// is the point of keeping it.
            let markup: Int
            static let nothing = Drawn(text: 0, media: 0, markup: 0)
            /// One picture, or roughly a sentence, laid out.
            var hasDrawn: Bool { media >= 1 || text >= 80 }
            /// 39 characters is `<html><head></head><body></body></html>`, the
            /// skeleton a web view starts with. Anything more means a document
            /// arrived, whatever the layout probe says about it.
            var hasDocument: Bool { markup > 39 }
        }

        private static let paintProbe =
            "(function(){var b=document.body;if(!b){return [0,0,0];}"
            + "var t=(b.innerText||'').trim().length;"
            + "var m=b.querySelectorAll('img,svg,canvas,video,iframe').length;"
            + "return [t,m,document.documentElement.outerHTML.length];})()"

        private static func measure(_ web: WKWebView) async -> Drawn {
            guard let values = (try? await web.evaluateJavaScript(paintProbe)) as? [Int],
                  values.count == 3 else { return .nothing }
            return Drawn(text: values[0], media: values[1], markup: values[2])
        }

        private static let pollInterval: UInt64 = 200_000_000
    }
}

/// What the reader looks at while the original page loads underneath.
///
/// It counts, and that is the whole point of it. A spinner that never changes
/// is indistinguishable from a hang, and some of these waits are long for
/// honest reasons: `adam.math.hhu.de` sends a 6 MB JavaScript bundle from a
/// server running at about 175 KB/s, so `isLoading` stays true for 45 seconds
/// before anything can possibly appear. A number that goes up says the app is
/// still working; a still spinner says nothing at all.
///
/// There is no progress bar because there is no honest number to put in one.
/// `estimatedProgress` sat at 0.136 for the whole of those 45 seconds — it
/// follows the document, not the megabytes of script the document then asks
/// for. A bar frozen at 14% would be worse than no bar.
private struct LivePageCover: View {
    let host: String
    let link: URL
    @State private var elapsed = 0

    /// When to stop apologising and start explaining. Below this a wait is
    /// ordinary and needs no comment.
    private static let longWait = 6

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("The reader could not lay this one out.")
                .font(.custom("Charter", size: 14))
            Text("Fetching \(host)\u{2026} \(elapsed)s")
                .font(.custom("Charter", size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if elapsed >= Self.longWait {
                // Some pages arrive as an empty shell and build themselves
                // once they are running, and a few are very large. Saying so
                // turns a suspicious wait into an explained one.
                Text("This page builds itself once open, which can take a while "
                     + "on a large site.")
                    .font(.custom("Charter", size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Open in Browser") { NSWorkspace.shared.open(link) }
                    .buttonStyle(.link)
                    .font(.custom("Charter", size: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                elapsed += 1
            }
        }
    }
}

// MARK: - PDF rendering

/// Native PDF reader for items that link straight to a PDF.
///
/// The bytes are downloaded and capped here, then handed to the sandboxed
/// helper in `Contents/XPCServices/PDFService.xpc`, which parses them and
/// returns page images. This process does not link PDFKit at all, so a
/// malformed document cannot reach a parser inside the app.
///
/// See `IsolatedPDFView` for what that costs: PDFKit's text selection and find
/// bar are not available, because both need the document in this process.
private struct PDFReader: View {
    let url: URL
    /// Called when the download turns out to be a web page rather than a PDF,
    /// so the reader can run its normal extraction instead.
    var onNotAPDF: () -> Void = { }
    @State private var model = IsolatedPDFModel()
    /// 1.0 fits the pane. Zoom re-renders through the helper rather than
    /// scaling a bitmap, so a magnified page stays sharp.
    @State private var zoom: CGFloat = 1.0

    private static let zoomStep: CGFloat = 0.25
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...4.0

    var body: some View {
        ZStack {
            switch model.state {
            case .ready(let pageCount):
                IsolatedPDFPages(model: model, pageCount: pageCount, zoom: $zoom)
                    .overlay(alignment: .bottomTrailing) { zoomControls }

            case .failed(let why):
                // Previously this was a white page: `defer { onLoaded() }`
                // lifted the cover whether or not a document had arrived, so a
                // failure revealed an empty viewer and said nothing.
                //
                // It now also covers a helper that died on a malformed
                // document, which is the case the helper exists for: a crash
                // over there has to become a sentence over here.
                ReaderNotice(problem: ReaderView.Problem(
                    headline: "This PDF would not open",
                    advice: "The file could not be downloaded or could not be "
                          + "read as a PDF. Opening it in your browser is the "
                          + "quickest way to see it, and will also show you "
                          + "whether the file itself is the problem.",
                    technical: why), link: url, retry: {
                        Task { await model.load(url) }
                    })

            case .starting, .downloading:
                VStack(spacing: 14) {
                    // Three states, not two. A server that declares no length
                    // gets a spinner and a running byte count rather than the
                    // bare "Loading PDF…", which is what happened on a 7.4 MB
                    // report that took 163 seconds: `Content-Length` was
                    // absent on that request, so the determinate branch never
                    // fired and the reader got no sign of progress for nearly
                    // three minutes.
                    if case .downloading(let got, let total) = model.state, total > 0 {
                        ProgressView(value: Double(got), total: Double(total))
                            .frame(width: 220)
                        Text("\(Self.mb(got)) of \(Self.mb(total))")
                            .font(.custom("Charter", size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if case .downloading(let got, _) = model.state {
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
        .task {
            model.onNotAPDF = onNotAPDF
            await model.load(url)
        }
        .onDisappear { model.close() }
    }

    /// Zoom, because the helper renders at a fixed width and the reader has no
    /// `PDFView` to do it any more. Keyboard shortcuts as well as buttons: a
    /// document viewer without command-plus is a document viewer someone will
    /// complain about.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                zoom = max(Self.zoomRange.lowerBound, zoom - Self.zoomStep)
            } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= Self.zoomRange.lowerBound)

            Button { zoom = 1.0 } label: {
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Fit to the width of the pane")

            Button {
                zoom = min(Self.zoomRange.upperBound, zoom + Self.zoomStep)
            } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(zoom >= Self.zoomRange.upperBound)
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    /// A file size the way macOS states one.
    ///
    /// `ByteCountFormatter` with `.file` is what Finder uses, so the reader
    /// and the Finder agree about the same document. Dividing by 1,048,576 and
    /// printing "MB" did not: Finder calls that 7.44 MB where the app said
    /// 7.1 MB, because macOS has counted file sizes in decimal since 10.6 and
    /// only `ls -lh` still reports binary. The formatter also localises the
    /// unit and the separator, which a `String(format:)` never will.
    private static func mb(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
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
    /// Called when the host page never rendered. The reader owns the notice;
    /// this view only reports.
    var onFailure: () -> Void = {}

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
        jdnLog("video: loading \(what) — \(html.count) char host page")
        context.coordinator.show(html, baseURL: baseURL, in: web,
                                 what: what, onFailure: onFailure)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Watches for the failure this path could not previously report.
    ///
    /// The host page is a short `<iframe>` wrapper handed to `loadHTMLString`,
    /// which is the API that fails on both machines this app has been tested
    /// on, and this path had no blank detection, no logging and no failure
    /// state — so a video that would not play was a black rectangle and
    /// silence. That was the fourth place in this app where a missing check
    /// turned a failure into a blank pane.
    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        var loaded = false
        private var check: Task<Void, Never>?

        /// A player needs longer than a document: the host page loads, then
        /// the iframe, then the player's own scripts.
        private static let grace: TimeInterval = 8
        private static let emptyDocumentChars =
            "<html><head></head><body></body></html>".count

        func show(_ html: String, baseURL: URL?, in web: WKWebView,
                  what: String, onFailure: @escaping () -> Void) {
            web.loadHTMLString(html, baseURL: baseURL)
            check?.cancel()
            check = Task { @MainActor [weak web] in
                try? await Task.sleep(nanoseconds: UInt64(Self.grace * Double(NSEC_PER_SEC)))
                guard !Task.isCancelled, let web else { return }
                let probe = "document.documentElement.outerHTML.length"
                let chars = (try? await web.evaluateJavaScript(probe)) as? Int ?? 0
                guard chars <= Self.emptyDocumentChars else {
                    jdnLog("video: \(what) host page rendered \(chars) chars")
                    return
                }
                jdnLog("video: \(what) drew nothing after \(Int(Self.grace))s — "
                       + "the host page never rendered")
                onFailure()
            }
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

/// Native player for direct media files (`.mp4`, `.mov`, …), behind two gates.
///
/// **Nothing is fetched until the reader asks for it.** It used to build the
/// player and call `play()` in `onAppear`, so opening an article was enough to
/// start fetching and decoding whatever a feed had linked. AVFoundation is a
/// large C and C++ parser running in this process — unlike PDFKit it cannot be
/// moved into a helper, because `AVPlayer` renders through a view — so the
/// difference between "a feed can do this" and "a feed can do this if you press
/// play" is the whole mitigation.
///
/// **And the bytes are looked at before the player sees them.** `AVPlayer`
/// decides what to do from content rather than from the path, and follows an
/// HLS playlist to URLs the app never checked. `VideoPreflight` reads a bounded
/// prefix, applies the same scheme and private-host rule as the rest of the
/// app, and refuses a playlist.
///
/// What none of this removes: decoding a genuine video file still happens in
/// this process. Only handing the URL to the browser would remove that, at the
/// cost of the player.
private struct NativeVideoView: View {
    let url: URL

    private enum Stage: Equatable {
        case waiting
        case checking
        case playing
        case refused(String)
    }

    @State private var stage: Stage = .waiting
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            switch stage {
            case .waiting:
                Button {
                    Task { await start() }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Play video")
                            .font(.custom("Charter", size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(url.host ?? "")
                            .font(.custom("Charter", size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)

            case .checking:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking the file\u{2026}")
                        .font(.custom("Charter", size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }

            case .playing:
                VideoPlayer(player: player)

            case .refused(let why):
                // Says what happened rather than showing a black rectangle,
                // which is indistinguishable from a video that has not started.
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("This video was not played")
                        .font(.custom("Charter", size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(why)
                        .font(.custom("Charter", size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .padding()
            }
        }
        .onDisappear { player?.pause() }
    }

    private func start() async {
        stage = .checking
        switch await VideoPreflight.check(url) {
        case .refuse(let why):
            stage = .refused(why)
        case .play:
            let p = AVPlayer(url: url)
            player = p
            stage = .playing
            p.play()
        }
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
