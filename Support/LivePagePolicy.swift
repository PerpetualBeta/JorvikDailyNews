import Foundation

/// Whether the live-page fallback runs the site's own scripts.
///
/// Its own file rather than a property of `LiveWebView`, so the suite can
/// exercise it: an undefended default is how a setting like this drifts.
enum LivePagePolicy {

    /// Whether the live page is allowed to run the site's own scripts.
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews allowScriptsOnLivePage -bool YES
    ///     defaults delete cc.jorviksoftware.JorvikDailyNews allowScriptsOnLivePage
    ///
    /// **Off by default, and this is the one setting in the app that trades
    /// working websites for privacy.**
    ///
    /// It used to be on, with the reasoning that scripts run in WebKit's own
    /// sandboxed content process and can therefore reach no more than any
    /// browser allows. That is true and it is not the whole question. This is
    /// the only view in the app that runs a stranger's code, and a script can
    /// read a reply and send it onward — which turns the app's one open
    /// residual, a public name resolving to a private address, from a blind
    /// request into a readable one. Nothing in the address blocklist helps:
    /// the name is public, and it is only the number behind it that is not.
    ///
    /// The reader's own pane and every extraction rung already run with
    /// scripting off (`allowsContentJavaScript = false` at :681 and in
    /// `ArticleExtractor`); this was the exception.
    ///
    /// Off costs real sites. Plenty of pages render nothing without their
    /// scripts, and this view is the last resort when everything else has
    /// failed, so off makes some of those articles unreadable in the app. That
    /// is a trade worth offering rather than deciding for everyone, which is
    /// why it is a switch and why the default is the private one.
    ///
    /// Read through `object(forKey:)` rather than `bool(forKey:)` so the two
    /// readings agree on what an unset key means.
    static let allowScriptsKey = "allowScriptsOnLivePage"

    static var allowsScripts: Bool {
        UserDefaults.standard.object(forKey: allowScriptsKey) as? Bool ?? false
    }

    /// Whether the live page may load this address.
    ///
    /// **Cleartext is refused here rather than by App Transport Security.**
    /// The app used to carry `NSAllowsArbitraryLoadsInWebContent = false`
    /// alongside `NSAllowsArbitraryLoads = true`, meaning "cleartext for
    /// fetching, none for web views". That is not what it does: ATS ignores
    /// `NSAllowsArbitraryLoads` whenever the web-content key is **present**,
    /// whatever value it carries. Proved with two app bundles differing in
    /// nothing else, fetching the same five plain-http feeds — without the
    /// key, three returned 152 KB, 48 KB and 190 KB and the other two failed
    /// for reasons of their own; with it, all five were ATS BLOCKED. Every
    /// remaining http feed had been failing hourly, in silence, since it
    /// shipped.
    ///
    /// The reasoning behind the refusal stands: this view runs the page's own
    /// scripts, and over cleartext an on-path attacker can rewrite that page
    /// and run script inside the app's chrome, where there is no address bar
    /// to check. It is one test in the one view that loads a remote page.
    static func permitsLivePage(_ url: URL) -> Bool {
        guard WebURL.isAllowed(url) else { return false }
        return url.scheme?.lowercased() != "http"
    }
}
