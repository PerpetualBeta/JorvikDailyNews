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

## When a feed goes quiet

A line under the dateline says so, and it says which of two things has happened.

*"... has not been reachable for over a day"* means the fetch itself is failing. A publisher being down overnight is not worth mentioning, so the threshold is a day.

*"... has published nothing for over a year"* means the opposite: the feed answers perfectly and nobody is writing it any more. Nothing in the app could see this before, because every health signal it had was about the fetch rather than about the contents.

Both name the feeds while there are three or fewer and count them after that, and both link straight to Manage Feeds.

**Each quiet feed is mentioned once.** On a long subscription list this is not a rare event: of 238 active feeds on one real list, 89 had published nothing for over a year and 72 nothing for over two, the oldest since December 2005. A line saying so every morning would be a nag rather than a note, so the paper says it as each feed crosses the line and then leaves it alone. If the feed starts publishing again and later stops again, it is mentioned again.

The standing truth lives in Manage Feeds instead, where a grey **QUIET** badge marks every such feed and its tooltip gives the date it last published. That is the list to work through when you want to prune.

Every row there also carries a compass button that opens the **site** in your browser, not the feed. Opening a feed's own address gives a page of XML, which tells you nothing about whether the subscription is worth keeping; the button uses the site link the feed itself publishes, falling back to its host when it publishes none.

## Unread only

Toggle in the toolbar. When on, read items are removed from the paper and the front page reflows — the next unread story takes the lead slot, secondaries refill, etc. When off, read items stay visible at 55% opacity as a "you've been here" affordance.

## Reader pane

Clicking a headline replaces the paper with an inline reader view (not a separate window). Mozilla Readability extracts the article's main content, and **the reader draws it directly in SwiftUI — there is no web view in the article path at all**. Charter at a 680 px column, dark-mode aware, with every measurement taken from the stylesheet the HTML renderer used to apply.

That is not a tidying-up. The reader used to hand the extracted HTML back to a web view, by exactly the call that had already been measured dead on macOS 27, so the machine where extraction was *fixed* would have shown a blank sheet where it previously showed the real website. Drawing the article natively removes the last thing in the reading path that can fail silently: no renderer process, no navigation, nothing to park.

The article arrives as typed blocks — paragraphs, headings, lists with their nesting, quotes, code, tables, pictures and inline SVG — walked out of Readability's output in the same `JavaScriptCore` pass, from the same DOM. Links inside an article open in your browser; a `mailto:` link shows you the address first, and what it would send. `esc` or **Back to Paper** returns. **Open in Browser** in the header bar takes you to the original article at any time.

The reader header always shows where the material comes from: the feed's name, and beneath it the destination **host** (`economist.com`, `youtube.com`, …) in plain monospace. It's there in every reader state — article, live page, PDF, or video — so even a chrome-free embedded video tells you its source at a glance.

**Re-classify on the fly.** The header's section menu shows the article's current section ticked; pick another to move it *and* train the classifier, exactly as the right-click "Move to…" menu on the paper does — no need to leave the reader.

**Exclude a source.** The header's **Exclude Source** button drops every item pointing at the current article's host from the paper and reflows immediately. The aggregator feed that surfaced it keeps flowing — only items pointing at that host disappear. Useful for muting a domain that a dozen feeds all keep linking to.

## When the reader can't extract an article

Some pages defeat extraction. When every route fails, the reader shows you the real website instead of an empty pane.

**That view runs with the site's scripts turned off**, which is the only place in the app where a choice has been made that can make a page less useful. Many sites render nothing at all without their scripts, so an article that ends up here may look broken rather than merely plain. If you would rather have the working page:

```
defaults write cc.jorviksoftware.JorvikDailyNews allowScriptsOnLivePage -bool YES
```

`defaults delete` the same key puts it back. Either way it applies to the next article you open.

**The reason for the default.** A script on a page can ask for a web address and read what comes back. The app refuses addresses that name a machine on your own network, but that check reads the *address* — and a perfectly ordinary-looking name can be pointed at a machine in your house by whoever owns the name. With scripts off, the worst that happens is a request going somewhere it should not, and nothing comes back out. With scripts on, a page can read the answer and send it on.

That is the whole trade, and it is a small risk against a real cost, which is why it is yours to make rather than ours. [The security notes](security.md) go through it properly.

**You will be told when it happens rather than left on an empty page.** A page that arrives in full and puts nothing on screen gets an explanation naming the reason and the command, with **Open in Browser** beside it. The first one found in ordinary use was `jeffbaumes.github.io/all-decks/`, which is a single `<canvas>` and a script that draws playing cards into it: 21,438 characters of markup and not one character of text without its script.

---

[← Back to the README](../README.md)
