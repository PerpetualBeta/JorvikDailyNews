# Using It

*Adding feeds, importing and exporting, pausing a source, and everything the reader pane does.*

| Action | Shortcut |
|---|---|
| Add Feed | `command` `N` |
| Refresh | `command` `R` |
| Manage Feeds | `shift` `command` `F` |
| Import OPML | `shift` `command` `O` |
| Export OPML | `shift` `command` `E` |
| Front Page | `command` `1` |
| Previous Page | `command` `left` |
| Next Page | `command` `right` |
| Scroll to top / bottom | `Home` / `End` |
| Scroll by viewport | `PgUp` / `PgDn` |
| Back to paper (from reader) | `esc` |

## Adding feeds

`command` `N` → paste a feed URL *or a site's home page* → optionally tag with a section → Add. The app auto-discovers feeds: paste `https://arstechnica.com` and it finds the feed via `<link rel="alternate">` in the page head. If the page declares no feed, common paths (`/feed`, `/rss`, `/atom.xml`, `/feed.xml`, …) are probed as a fallback. Duplicates are rejected after resolution — you can't accidentally add the same subscription twice.

## Bulk import / export

`shift` `command` `O` imports an OPML subscription list from any reader. Nested `<outline>` categorisation becomes sections. Duplicates against your existing feeds are skipped. `shift` `command` `E` exports your feed list back out as OPML 2.0 — round-trips cleanly.

## Pausing a feed

Manage Feeds (`shift` `command` `F`) → pause icon on any row. The feed's items vanish from today's paper immediately (no network round-trip); un-pausing triggers a refresh so they come back. Useful when a feed is too noisy on a given day and you want to mute it without deleting the subscription.

## Unread only

Toggle in the toolbar. When on, read items are removed from the paper and the front page reflows — the next unread story takes the lead slot, secondaries refill, etc. When off, read items stay visible at 55% opacity as a "you've been here" affordance.

## Reader pane

Clicking a headline replaces the paper with an inline reader view (not a separate window). Mozilla Readability extracts the article's main content, and **the reader draws it directly in SwiftUI — there is no web view in the article path at all**. Charter at a 680 px column, dark-mode aware, with every measurement taken from the stylesheet the HTML renderer used to apply.

That is not a tidying-up. The reader used to hand the extracted HTML back to a web view, by exactly the call that had already been measured dead on macOS 27, so the machine where extraction was *fixed* would have shown a blank sheet where it previously showed the real website. Drawing the article natively removes the last thing in the reading path that can fail silently: no renderer process, no navigation, nothing to park.

The article arrives as typed blocks — paragraphs, headings, lists with their nesting, quotes, code, tables, pictures and inline SVG — walked out of Readability's output in the same `JavaScriptCore` pass, from the same DOM. Links inside an article open in your browser; a `mailto:` link shows you the address first, and what it would send. `esc` or **Back to Paper** returns. **Open in Browser** in the header bar takes you to the original article at any time.

The reader header always shows where the material comes from: the feed's name, and beneath it the destination **host** (`economist.com`, `youtube.com`, …) in plain monospace. It's there in every reader state — article, live page, PDF, or video — so even a chrome-free embedded video tells you its source at a glance.

**Re-classify on the fly.** The header's section menu shows the article's current section ticked; pick another to move it *and* train the classifier, exactly as the right-click "Move to…" menu on the paper does — no need to leave the reader.

**Exclude a source.** The header's **Exclude Source** button drops every item pointing at the current article's host from the paper and reflows immediately. The aggregator feed that surfaced it keeps flowing — only items pointing at that host disappear. Useful for muting a domain that a dozen feeds all keep linking to.

---

[← Back to the README](../README.md)
