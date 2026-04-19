import SwiftUI
import WebKit
import AppKit

/// Reader view rendered inline inside the main window (not a modal sheet) —
/// the newspaper "turns to" the article, and Back returns to the paper.
struct ReaderView: View {
    let item: FeedItem
    @Environment(AppStore.self) private var store

    @State private var state: ReaderState = .loading

    enum ReaderState {
        case loading
        case ready(ArticleExtractor.Article)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: item.id) { await extract() }
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

        case .failed(let reason):
            ScrollView {
                VStack(spacing: 18) {
                    Text("Can\u{2019}t render a reader view")
                        .font(.custom("Didot", size: 28))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.custom("Charter", size: 15))
                            .lineSpacing(4)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 620)
                            .padding(.top, 12)
                    }
                    Button {
                        NSWorkspace.shared.open(item.link)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(48)
            }
        }
    }

    private func extract() async {
        state = .loading
        let extractor = ArticleExtractor()
        do {
            let article = try await extractor.extract(url: item.link)
            state = .ready(article)
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
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(html, baseURL: baseURL)
    }
}
