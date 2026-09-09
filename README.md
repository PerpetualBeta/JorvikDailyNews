# Jorvik Daily News

A macOS RSS reader shaped like a daily newspaper. The paper only shows items whose published date falls inside today's local calendar — older items never appear, no matter how unread they are. Launch refreshes automatically and the paper re-fetches on each clock hour while it's open; `command` `R` republishes on demand. Anti-doomscroll: no unread counts, no infinite stream, finite by design.

![The front page — a full-width lead above a three-column masonry](docs/screenshots/front-page.png)

## Requirements

- macOS 14 (Sonoma) or later
- Any RSS, Atom, or JSON feed URLs you want to read

## Installation

Two formats on every release — both signed and notarised:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/JorvikDailyNews/releases/latest/download/JorvikDailyNews.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/JorvikDailyNews/releases/latest)** — unzip and drag `JorvikDailyNews.app` to your Applications folder.

Or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask perpetualbeta/jorvik/jorvik-daily-news
```

## Why

RSS readers are streams. Streams never end. You open the reader, scroll past the same headlines you already ignored, and close it again no better informed.

A newspaper is the other shape. It publishes for a specific day, it's finite, you finish it. This app takes your feeds and publishes only what came out *today* — no yesterday's leftovers, no unread counts shaming you into scrolling. You read the paper, put it down, and get on with your day.

## How It Works

The paper is rebuilt from whatever your feeds have published today. While the app is open it re-fetches on each clock-hour boundary (09:00, 10:00, 11:00…) and again on wake-from-sleep, so the paper stays current without ever showing stale content. Once the clock rolls past midnight, today's paper starts fresh; the app keeps only the last few days of editions on disk and clears older ones automatically, because the whole point is today's news.

**A section page holds sixty stories, and it used to hold everything left over.** A busy News section put 505 items on one page, and the cost is not drawing them: every card in the masonry publishes its height through a `GeometryReader`, and every height arriving triggers a redistribute, so 505 cards are a measure-and-relayout storm on the main thread. The page took seconds to open and spun the beachball while it did. A newspaper page has an extent, so an oversized section now becomes several pages of the same name and the title reads `News (2 of 9)`. On the day this was measured that took the largest page from 505 items to 60 and the whole paper from 9 pages to 17. `sectionPageCap` tunes it live, because how a page turn feels is not a matter of arithmetic.

The front page is a full-width lead story above a 3-column masonry of the rest of the day's news. The builder prefers a lead carrying both halves — a picture that actually loads, validated and warmed before publishing, and text to read under the headline — but never leaves the page without one: failing that it takes a story with a picture, then one with text, then whatever the paper has. A lead with no picture becomes a full-width headline over a two-column deck. Section pages follow if you've tagged feeds by topic (News / Tech / Culture / …). Click any headline to read the article in a clean reader pane — extracted via Mozilla's Readability, rendered in serif type, no ads, no trackers.

## Screenshots

| | |
|---|---|
| ![A topic section page](docs/screenshots/section-page.png) | ![The Add Feed sheet](docs/screenshots/add-feed.png) |
| Section pages collect a topic's stories into their own masonry. | Add a feed by URL — or paste a site's home page and it finds the feed. |
| ![The feed manager](docs/screenshots/manage-feeds.png) | |
| Manage Feeds: search, section, pause, or remove; a colour dot shows each feed's fetch health. | |

## Using It

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

### Adding feeds

`command` `N` → paste a feed URL *or a site's home page* → optionally tag with a section → Add. The app auto-discovers feeds: paste `https://arstechnica.com` and it finds the feed via `<link rel="alternate">` in the page head. If the page declares no feed, common paths (`/feed`, `/rss`, `/atom.xml`, `/feed.xml`, …) are probed as a fallback. Duplicates are rejected after resolution — you can't accidentally add the same subscription twice.

### Bulk import / export

`shift` `command` `O` imports an OPML subscription list from any reader. Nested `<outline>` categorisation becomes sections. Duplicates against your existing feeds are skipped. `shift` `command` `E` exports your feed list back out as OPML 2.0 — round-trips cleanly.

### Pausing a feed

Manage Feeds (`shift` `command` `F`) → pause icon on any row. The feed's items vanish from today's paper immediately (no network round-trip); un-pausing triggers a refresh so they come back. Useful when a feed is too noisy on a given day and you want to mute it without deleting the subscription.

### Unread only

Toggle in the toolbar. When on, read items are removed from the paper and the front page reflows — the next unread story takes the lead slot, secondaries refill, etc. When off, read items stay visible at 55% opacity as a "you've been here" affordance.

### Reader pane

Clicking a headline replaces the paper with an inline reader view (not a separate window). Mozilla Readability extracts the article's main content; a hand-tuned stylesheet renders it in Charter at 680 px column width, dark-mode aware. High-contrast colour rules override anything low-contrast the source page ships. `esc` or **Back to Paper** returns. **Open in Browser** in the header bar takes you to the original article at any time.

The reader header always shows where the material comes from: the feed's name, and beneath it the destination **host** (`economist.com`, `youtube.com`, …) in plain monospace. It's there in every reader state — article, live page, PDF, or video — so even a chrome-free embedded video tells you its source at a glance.

**Re-classify on the fly.** The header's section menu shows the article's current section ticked; pick another to move it *and* train the classifier, exactly as the right-click "Move to…" menu on the paper does — no need to leave the reader.

**Exclude a source.** The header's **Exclude Source** button drops every item pointing at the current article's host from the paper and reflows immediately. The aggregator feed that surfaced it keeps flowing — only items pointing at that host disappear. Useful for muting a domain that a dozen feeds all keep linking to.

## Smart Content Handling

### Standfirsts

A feed's body is HTML, and the only record of a paragraph break in it is a tag. Turning that HTML into plain text by replacing every tag with a space destroys the breaks, which is how a card ends up with the whole article compacted into one unreadable run. The app splits the body on its block boundaries first, so the paragraphs survive, and then takes the opening ones as a standfirst.

Which blocks count is decided structurally, not by a list of phrases to ignore. An image credit, a bare URL, an `iPad | Mac | iPhone` link row and a social strip have nothing in common textually, but all of them are far shorter than a paragraph of prose, so a minimum word count separates them without anyone having to enumerate them. Measured across 5,368 blocks from 39 subscribed feeds, real opening paragraphs run 20 words and up while that leading noise is 14 words or fewer; the threshold sits at 15, and anything from 8 to 20 gave an identical result on that sample. Code listings, scripts, stylesheets, tables and figure captions are dropped whole. Inline `<code>` is kept, because removing it puts holes in sentences.

Character references are decoded in a single left-to-right pass that never re-reads what it has written. A sequence of find-and-replace passes cannot do this: replacing `&amp;` first turns a literal `&amp;lt;` into `&lt;`, and the later pass turns that into `<`, so text the source deliberately escaped comes out as markup. Numeric references are decoded arithmetically rather than listed, which is where a fixed list failed and failed widely — across those same feeds `&#039;` appears 3,073 times, `&#8217;` 1,720, `&#39;` 1,164, `&#92;` 410 and `&#xA0;` 397, against a table holding only two of them, and a leading zero alone was enough to defeat it. Named references are a small closed set in practice (16 distinct across 39 feeds) but their tail is accented letters, so the table is generated from the HTML5 named-character-reference set rather than typed out. Nothing entity-shaped survives extraction anywhere in the sample.

Paragraphs accumulate up to a word target, and the one that crosses it is cut at a sentence rather than mid-thought. Sentence-at-a-time matters for the feeds that ship an entire article as a single `<p>` — one in that sample arrived as a 717-word paragraph — where there is no structure left to recover and only a sentence boundary can stop the wall reaching the page. That target is a storage bound rather than a layout one: it decides how much material the paper has to choose from, not how much of it appears.

### Fitting a standfirst to its space

How much appears is measured, not estimated. A standfirst is laid out with the real font at the real width before it is drawn, and cut to the last whole sentence that fits the lines available. Nothing sets a line limit, which is the point — a line limit clips the rendering and drops its ellipsis wherever the line happens to break, usually mid-word. Cutting the content instead means there is nothing left to truncate. Across the sample no column is cut mid-sentence at any of the four widths the paper can present; the only columns not ending in a full stop are ones ending at a paragraph break on a colon, or ones whose source text carries no terminal punctuation at all.

The one deliberate exception is a single sentence longer than the space it has. That is shown whole and allowed to overrun rather than replaced with nothing.

A headline whose last line would hold a single word gets its last two words bound together with a non-breaking space, pulling the previous word down to keep it company. A one-word last line reads as though the headline ran out rather than ended, and it is most obvious on the side-by-side lead where the headline is set to half the measure. It is applied only where it is needed and only where it helps: the headline is laid out first to see whether the last line really is one word, and the bound pair is measured to confirm it still fits, since a pair too long for the column would break the line somewhere worse than the runt it was meant to fix.

### Adaptive columns

Type is comfortable to read between roughly 45 and 75 characters a line, with about 66 as the ideal. Set across the full width of the page the lead ran to 113, half as long again as it should be, so a standfirst is set in as many columns as its width warrants: the planner rounds to the nearest whole number of ideal-width columns, an ideal column being 440pt at Charter 14, which is where the measurement puts 66 characters.

In practice that means two columns for the lead at every window size the app allows, giving a measure of 58 to 75 characters, and one column for a card. A single-column lead is only chosen below about 600pt of page width, which the 900pt window minimum puts out of reach; it would become reachable if the window were allowed narrower. Three columns arrive above about 1350pt, which the 1100pt page cap likewise puts out of reach today. Both fall out of the rule rather than being special-cased, so they follow if those limits ever move.

A column does not end on a single word, unless the alternative is losing it. The obvious fix is to tie the last two words together, and on its own that is unsafe here: the text has already been cut to a fixed number of lines, so suppressing a break can push the final words onto a line that does not exist and the reader loses them altogether, which is worse than an orphan. So the guard lives inside the fitting where the line budget is known: join, re-count the lines, and keep the joined version only if the column is still within budget. Measured across widths from 240 to 420 points on one real standfirst, exactly one width produced an orphan and the guard fixed it while leaving the other nine untouched. The join is a word joiner either side of the space rather than a no-break space, because Charter's U+00A0 advances 7.79pt against a 3.89pt normal space and would put a visible gap mid-sentence.

Columns divide at a line, not at a sentence. Where the text *ends* has to be a whole sentence, because the reader has nowhere to continue; where one column *hands over* to the next is not a truncation at all, since the sentence carries on at the top of the next column exactly as a newspaper's does. Dividing at sentences instead left a four-line column beside a seven-line one, because a paragraph too big for its share has to go over whole.

How many columns the width allows is not how many the text wants. A two-line standfirst divided in two leaves half a sentence stranded across the gutter, reading as a fault rather than a deck, so a column has to carry at least three lines to earn its place; below that the deck takes a single column and leaves the rest of the measure as white space, which is what a newspaper does with a short deck. The column keeps its planned width either way, so the line length stays comfortable. The line index only estimates this, because a column that inherits a paragraph break loses the blank line to trimming and draws shorter than its share, so the estimate is only a starting point and the drawn result decides: a column is dropped and the text re-split until every column that exists earns its place. In practice the ladder runs one column up to six lines and two from seven.

A short deck also changes the lead's shape. A full-width picture stacked over a one-line standfirst leaves the whole right-hand measure empty, so the lead is set across instead of down: picture in one column, source, headline and deck in the other. The trigger is the planner's own answer rather than another threshold — a deck short enough to want a single column is short enough to sit beside the picture. A lead with no picture stays stacked, since there is nothing to sit beside.

An even share of the line index still is not an even share of the drawn column: the blank line a paragraph break leaves behind counts as a line but is trimmed off the column that inherits it, pulling that column up to two lines short. So each boundary is nudged a line either way and the split that draws most evenly wins. Across the sample the columns now differ by at most one line, which is the floor — an odd number of lines cannot divide evenly in two. Re-planning costs a handful of layout passes, so results are cached on the text, width, font and line allowance together.

Every item is stored at the lead's length, because any item can be promoted to lead when the paper reflows and the body HTML is not kept in the edition to re-extract from. Re-extracting the real feeds at each candidate length puts the share of leads filling 14 of the deck's 16 lines at 67% for 150 words, 72% for 180 and 75% for 210, after which the feeds have no more to give; the target sits at 200, just under that plateau. Overshooting costs only disk, since the fitter cuts whatever will not fit. The knobs are `summaryMinParagraphWords`, `summaryLeadTargetWords` and `standfirstIdealColumnWidth`.

### Page metadata enrichment

A page's own description has to be long enough to be a sentence before it is used as a standfirst. Global Times declared its description as exactly "The flames of a", and JDN printed that as a lead's entire deck. Measured across 1,002 stored summaries from seven editions, five words rejects 15 of them and every one is a fragment; eight would reject 39 and start taking readable ones with it (`summaryMinDescriptionWords`). It is deliberately lower than the 15-word paragraph threshold, which was measured on body prose rather than on descriptions written to be short. Word count cannot do all of the work: at ten words, "Contribute to X development by creating an account on GitHub" is boilerplate and "Governors crack down on licence-plate-reading start-up bankrolled by Trump donors" is a good standfirst, so this only removes what is too short to be a sentence at all. An item left without a standfirst cannot anchor the lead, which wants both halves.

When a feed ships no image **or no standfirst**, the target page's own `<head>` supplies what is missing: `og:image` / `twitter:image` / `<link rel="image_src">` for the picture, `og:description` / `twitter:description` / `<meta name="description">` for the text. One fetch answers both, so an item short of either is worth the round trip. Whatever the feed did supply is never overwritten — the page's own metadata is a fallback for what is absent, not a better source.

Enrichment is measured against the pool you can still see, not against the edition, and its budget is an outcome rather than a count: keep fetching until at least 30% of a page's articles carry a picture, or until the section runs out of pages to ask (`imageCoverageTarget`). A position cap could not express that. Enriching "the newest 24 of a section" meant the front page took the first 16 of them and the section page, which shows everything from item 17 onward, sat almost entirely outside the window — measured at 25% coverage against 100% on the front page. Each round takes, from every section still under target, the newest items with no picture that have not been asked about, capped at twelve per section so a burst cannot provoke the throttling that blanks pictures; rounds continue until the target is met or the candidates are exhausted. Without this the front page decays: a refresh enriches the newest 24 of the whole edition, but the visible paper is only the unread part of that and shrinks with every article opened, so it walks steadily into the tail that was never enriched and loses its pictures a few at a time. Simulated over an 84-item section, the front page holds at 11 or 12 pictures out of 16 across 48 articles read, against 6 to start.

It is a target, not a promise. Measured over 30 picture-less items from this paper's tail, only 3 offered an `og:image` at all — the rest are Show HN posts, Ask HN threads and repositories with no artwork anywhere to find. A section made of those stops short having tried everything, which is the right place to stop.

A page is asked about once. A page with no `og:image` is recorded as attempted and never fetched again, which is also what stops a reflow triggering fetches that trigger a reflow; the top-up also stands aside entirely while a refresh is in flight. In that simulation it fetched 42 pages across 48 articles read and never the same one twice.

The description half matters most for Hacker News, whose items carry only `Article URL: / Comments URL: / Points:` boilerplate where a standfirst would go. That boilerplate is cut wherever it starts rather than matched as a prefix, so a submitter who wrote something before it keeps their words and only the machinery goes. Just the two URL markers are matched, never `Points:` alone: hnrss always puts a URL marker first so cutting there takes the whole tail, while `Points:` turns up in real prose where it would truncate a genuine standfirst. That boilerplate is stripped, correctly, which used to leave those items with no text at all: 165 of 178 of them in one measured day, and a blank lead whenever one was promoted to it.

### Image enrichment

**The coverage target is 0.70, and at its old 0.30 the whole top-up was a no-op.** The top-up skips any section already at target, so with real coverage measured between 51% and 59% every section was above 0.30 and nothing was ever fetched. Pictures appeared to dry up as items were read, because hiding read items promotes items from deeper in the list and the only thing that would have fetched their pictures had quietly switched itself off. The new figure comes from the ceiling rather than from taste: sampling 40 picture-less unread items and fetching each, **23 declare no `og:image` or `twitter:image` at all, 14 have one and 3 would not fetch**, so about 35% of what is missing is recoverable and the reachable figure is near 68%. A target above that would burn rounds on pages with nothing to give. It is `imageCoverageTarget`, and it is worth re-measuring rather than trusting: the comment this replaced recorded 3 of 30, which is 10%, and that figure is what justified a target low enough to disable the feature.

**A page that would not fetch is asked again, twice, and then left alone.** Every item asked about is recorded so it is never asked twice, which is correct for a page that declares no picture, since the answer cannot change today. It was wrong for a page that timed out, and the two were indistinguishable until the enricher started reporting why a page yielded nothing. Three of those forty samples had failed to fetch rather than having nothing to give, and each had been written off for the day on one bad round trip.

The retry has to be counted, though, and the first version was not. Un-marking a failed page makes it eligible again immediately: it has no picture and has not been asked, so the next round picks it, it fails, and it is un-marked again. Two dead URLs were re-fetched every ten seconds indefinitely. `ImageCache` had already met this problem on the picture side and solved it with a cool-off, but a cool-off alone only slows the loop down. What ends it is a limit, so an item gets three attempts in total and the log says when one has used them all.

When a feed ships no image (HN, Daring Fireball, Michael Tsai), the target page is fetched for `<meta property="og:image">` / `twitter:image`. A refresh primes the newest 24 items *per section* so the paper opens with pictures before anyone has scrolled; from there the coverage target above decides how much further it goes. Per section, not per edition: the front page takes the newest items off the top, so a single edition-wide allowance was spent almost entirely on page one and the section pages got the text-only tail. Some sites publish their app icon as their social image, declaring the same file as both `og:image` and `rel="icon"` — a candidate that matches one of the page's own icon links is rejected and the next candidate tried, so a site icon never anchors a story. Where a feed *does* ship images but only tiny thumbnails (The Guardian's 140 px default), the widest declared size wins; undersized candidates fall through to the same og:image enrichment path.

### Image rendering

Pictures are never scaled above their own pixel size — a small site logo draws small, sharp and centred rather than blurred to fill the column — and are then held to a height cap. A card's is a fixed 260 points. The lead's is a share of the visible page, 46% of it, because a fixed cap turned a 2:1 photograph into a 3.1:1 letterbox at a wide window and discarded a third of its height for nothing: the cap is there to keep the headline above the fold at the smallest window, and at a large one there is no fold to protect. The share is that same constraint rewritten, derived so the 900x752 minimum still caps at 322 points exactly as the old fixed 320 did, while a page 1100 points tall shows that photograph uncropped. It stays a share rather than "whatever is left once the furniture is subtracted", because the furniture is a fixed number of points and subtracting it would let the picture take nearly the whole page at a tall window. A picture over its cap is cropped around whatever it actually shows, using Vision's attention saliency, so a phone screenshot crops to the dialogue in the middle rather than the status bar; when Vision finds nothing salient the crop stays top-aligned. These retune on a running copy: `cardImageMaxHeight` for a card, `leadHeroHeightFraction` for the lead's share of the page and `leadHeroMaxAspect` for its shape, with `leadHeroMaxHeight` overriding both of the lead's caps with an absolute one in points. A value of 0 removes a cap entirely. Sub-48-pixel images (tracking pixels, broken CDN placeholders) are rejected so they don't blot the page with empty rectangles.

Pictures can be turned off altogether, either for a Mac short of memory or to take them out of the reckoning while diagnosing something else:

```
defaults write cc.jorviksoftware.JorvikDailyNews showPictures -bool NO
```

Nothing is then downloaded and Vision never runs, and the front page falls back to a full-width headline over a two-column deck rather than leaving a hole where a hero would be — because with pictures off every image URL reports as unusable, which is the answer lead selection already knows how to act on. `defaults delete` the key to bring them back.

A failed picture is not necessarily a bad one. Gone, undecodable and tracker-sized are settled facts about a URL and are remembered for the session, because asking again cannot change the answer. A timeout, a dropped connection, a 5xx, a 429 or a 408 are not: those get a 60-second cool-off and are then tried again (`imageRetryCooloffSeconds`). Treating every failure alike meant one burst of throttling — a refresh firing dozens of concurrent requests at the same few CDNs — blanked every picture until the app was quit, and took the lead with it, since lead selection consults the same set. Images that fail to load collapse their slot — the headline rises into the vacated space.

A photograph of a person is cropped around the person. Vision's attention-based saliency answers "what is visually loudest", which on a portrait is the teeth and the collar line rather than the head, and centring on that answer cut the top of a subject's head off. Face detection runs first and attention saliency is the fallback for pictures with nobody in them; the face box is extended upward by a third of its height, because Vision bounds the face from chin to upper forehead and the crown and hair sit above that (`faceCrownAllowance`). What Vision returns is a vertical span rather than a centre point, because a centre cannot express "the subject is taller than the window you have" — and that case has a right answer: keep the top, since a cropped chin reads as a crop while a cropped crown reads as a mistake.

The lead prefers both halves and never disappears. A full-width slot carrying a picture and a headline but no standfirst reads as something that failed to load, so an item with both is preferred; failing that, one with a picture; failing that, one with a standfirst; failing that, anything the paper has. It is empty only when the paper is.

It used to fall away entirely when nothing had a usable picture, on the grounds that a text-only hero looks like a mistake at full-width span. That was true when the alternative was a bare headline over white space, and is not now that a picture-less lead is a full-width headline over a two-column deck — a paper with no art today rather than one that failed. It was also the wrong failure mode for the reason it usually fired: usable-image checks consult the image cache, so a moment of throttling, or simply having read every pictured story, took the whole lead with it. Losing the picture is a fair consequence of that. Losing the lead is not.

The lead is held to a stricter standard. Its image is validated and warmed before the edition publishes, so the hero renders the instant the page appears; a slow (>12 s) or dead lead image is recorded as failed and the edition rebuilt to pick the next usable-image story instead. All image fetches are coalesced — the lead's pre-fetch and the on-screen view share a single download per URL, rather than both hitting the host at once and tripping its rate limiter.

### In-app video

Video links play *inside* the paper, chrome-free, rather than kicking you out to a browser. YouTube and Vimeo render as a borderless embedded player (loaded through a host page so the player sees a legitimate third-party origin — no "Error 152/153"); direct media files (`.mp4`, `.m4v`, `.mov`, `.webm`) play in a native `AVPlayer`.

Most video feeds label their items `[video]` already, but some submitters don't — so any headline whose link plays in-app gets a `[VIDEO]` tag appended automatically when nothing in the title or summary already signals it. You always know you're about to open a video before you click — handy when you're in an office or a library.

### PDFs

A link to a PDF — by extension, or detected by content-type when the URL doesn't end in `.pdf` — opens in a native `PDFKit` view inside the reader, scrollable and zoomable, instead of downloading or bouncing to a browser.

**It reports the size and it can fail out loud.** A 7.4 MB report at 176 KB/s is forty-two seconds of waiting, and "Loading PDF…" for forty-two seconds cannot be told apart from a hang. The download is streamed rather than fetched whole, so the view shows a real progress bar and `2.1 MB of 7.4 MB`, updated five times a second rather than per byte. Before this, a failure was a **white page**: the cover over the PDF view was lifted by a `defer`, whether or not a document had arrived, so a failed download revealed an empty view and said nothing at all. Now a failure shows the same notice the reader uses, with the byte count and the reason, and **Open in Browser** as the way through. The request also has a timeout of its own; it previously had none and inherited `URLSession`'s default with no sign of which it was doing.

### Live page fallback

When Readability can't extract a clean article (paywalls, JavaScript-rendered SPAs, link-list pages), the reader doesn't dead-end you out to a browser: it renders the real page inline in a full web view. **Open in Browser** stays in the header as the escape hatch for anyone who wants it.

### Feed health

Each feed in Manage Feeds carries a colour dot: green (fetched cleanly and recently), orange (a little stale), red (repeatedly failing or long silent). Paused feeds show no dot — we deliberately stopped fetching them, so a "stale" warning would mislead.

## Storage

Everything under `~/Library/Application Support/JorvikDailyNews/`:

- `feeds.json` — feed list (URL, section, title, pause state)
- `editions/YYYY-MM-DD.json` — one file per published day; kept forever
- `read.json` — opened article IDs, persistent across sessions

**Pictures are cached on disk, and that is the one thing here that persists.** Before this the decoded bitmaps lived in memory only, so every launch re-downloaded every picture: around 350 requests for a full edition, every time, from sites that are mostly small and independent. Measured before the change, the app's URL cache held exactly **one** entry. Pictures now use their own `URLSession` with a 256 MB disk cache, and the log reports the hit rate once per launch so the benefit is a measurement rather than a claim. It reports over the **launch window** rather than the whole session, because that is the only stretch a cache can serve: measured on a real launch, all 14 disk hits arrived within **one second** of start-up and none of the following 76 pictures came from disk at all. A lifetime figure of "14 of 126" is arithmetically true and invites the wrong conclusion, since everything after the launch window is a story that did not exist an hour ago. Those first fourteen are the pictures already on the front page from last time, which is exactly the set that decides whether the paper appears at once or assembles itself while you watch. Its memory capacity is deliberately zero, because the decoded bitmaps are already cached in RAM and a second copy of the compressed bytes would only add pressure to the thing it is meant to protect. Caching follows the CDN's own headers, so a host sending `immutable` will hit almost every time and one sending `no-store` will never be cached, which is its right.

**Expiry is per layer, and the layers disagree.** The decoded bitmaps in memory have no expiry at all and are consulted *before* the disk cache, so the layer with proper HTTP freshness checking sits behind one with none: a CDN serving different bytes at the same address would be caught on revalidation and never get that far. Putting a lifetime on the memory cache would mean re-decoding pictures the CDN would have said were still fresh, which costs more than it saves, so instead the whole picture cache is dropped at the turn of the day, along with the set of URLs known to have failed and the ones in cool-off. An edition lasts a day, and a 404 yesterday is not evidence about today. Adding a correct cache behind an incorrect one does not make the pair correct; matching their granularity does.

The Vision crop spans were the worst of the four: a plain dictionary keyed by URL with no bound and no expiry, so every picture the app ever cropped added an entry for the life of the process and nothing removed one. Two numbers an entry, so the leak was small, but that is the same shape of mistake as setting `countLimit` without `totalCostLimit`. They live in an `NSCache` now, which also gives them up under memory pressure, which is right for a value recomputable from a picture still in hand.

Being straight about it: this means images from sites whose stories you have opened sit in `~/Library/Caches/JorvikDailyNews/Images` until they age out. That is pictures, not cookies, local storage or history, and the WebKit stores stay non-persistent as before. It is what every feed reader does, and it is a deliberate exception to "nothing persists" rather than an oversight.

No database. No telemetry. No cloud. No cookies — the reader pane uses ephemeral WebKit data stores that don't persist anything to disk or keychain. Reading an article fetches the article and nothing else. On the default path nothing but `URLSession` touches the network at all, because the HTML is parsed in `JavaScriptCore` with no web view involved; on the WebKit rungs the extractor refuses every subresource the page asks for. Either way its images, fonts, analytics beacons and tracking pixels are never requested.

## Updates

Updates are handled by [Sparkle](https://sparkle-project.org). The app checks for new versions automatically once a day in the background; **Jorvik Daily News → Check for Updates…** runs an on-demand check.

## Technical Details

- Pure Swift + SwiftUI. `swiftc -O` single-binary build — no Xcode project required.
- **The model layer compiles on its own.** Deciding whether a link is a video used to live on `ReaderView` as a static, and `Feed.displayTitle` called it to append `[VIDEO]` to a title, so a model type depended on a SwiftUI view. The cost was not tidiness: `FeedFetcher` could not be compiled without dragging in the whole interface, which is why the most testable code in the app — pure functions from bytes to items — had no tests and carried four faults from the day it was written. Classification needs no view, so it is now `VideoLink.detect` in its own file and `FeedFetcher`, `Feed`, `Edition`, `Standfirst` and `VideoLink` build together with nothing else. The player *markup* stays in the reader, because building an `<iframe>` host page is a view's business.
- Feed parsing via Foundation's `XMLParser`. RSS 2.0 and Atom 1.0. No third-party feed library.
- **Extraction runs a ladder of five strategies and stops at the first that yields a document.** Rung 1 does not use WebKit at all: it parses the fetched HTML with [LinkeDOM](https://github.com/WebReflection/linkedom) inside `JavaScriptCore` and runs Readability against that, so there is no web view, no renderer process, no navigation and nothing to fail silently. Whether an element is a container is decided by what is *not* inline, rather than by a list of block tags. That distinction is not pedantry: an allow-list of containers has to be complete to be correct and never will be. cultofmac.com nests a whole `<html><body>` inside its article content, so the structure reads `SECTION → HTML → BODY → 63 paragraphs`; `HTML` and `BODY` were not on the block list, the section looked as though it had no block children, and **all 9,893 characters came out as one paragraph**. The inline set is small, closed and defined by HTML itself, so anything else is walked into. That page went from 5 blocks with 1 paragraph to 66 blocks with 39.

Rungs 2 to 5 are the WebKit routes, tried in order: `loadHTMLString`, `loadSimulatedRequest`, the same bytes served over a private URL scheme, and a temporary file. The first rung to return an article is remembered for the rest of the run, so the ladder is walked once and not once per article. Rung 1 is first because it is both faster and better. Measured against the WebKit path on five live pages, the extracted body text is identical character for character on all four article pages (5,177, 5,249, 5,212 and 94,270 characters); the fifth is a link-list index page and differs by 24 characters of navigation whitespace. Parsing a 202 KB page takes 0.11s against 0.35s, and a typical page 0.03s against 0.16s. Bylines come out better rather than merely equal, because `allowsContentJavaScript = false` makes WebKit discard the contents of `<script type="application/ld+json">`, so the WebKit path has never been able to read a page's own structured data: a BBC article returns `Phil Cartwright` natively and nothing at all through WebKit. LinkeDOM parses with `htmlparser2` rather than a specification tree builder, so it will diverge from WebKit on badly-formed markup; a page where rung 1 finds no article therefore falls through to the WebKit rungs for a second opinion instead of ending the ladder. It also means the tree is repaired before Readability sees it. The specification says the "in head" insertion mode ends the moment a token appears that cannot be in `<head>`, at which point a browser pops `<head>` and everything after belongs to the body; `htmlparser2` keeps nesting instead. One real site serves `<!doctype html><html><head>` with **no `</head>` and no `<body>` anywhere**, which is legal, so its `<main>` landed inside `<head>`, the ancestor chain from any paragraph read `P → MAIN → HEAD → HTML` and never met `BODY`, and Readability walked off the top of the tree and threw on null. An entire article lost to a missing closing tag. The repair moves those nodes into the body as a browser would, and says so in the log when it acts: measured on that page, 6 nodes moved and an 11,239-character article recovered from nothing, with three well-formed pages producing byte-identical results before and after. `readerStrategy` pins a single rung by name for a diagnosis.
- Extraction is Mozilla [Readability.js](https://github.com/mozilla/readability) (Apache-2.0) run over a DOM supplied either by [LinkeDOM](https://github.com/WebReflection/linkedom) (ISC) in `JavaScriptCore`, or by `WKWebView`. Both are bundled as resources with their licences intact. Networking goes through `URLSession` with a desktop-Safari user agent; a web view, where one is used at all, only handles DOM and JavaScript.
- **On the WebKit rungs the extractor asks the DOM whether it is ready rather than waiting to be told.** WebKit's "finished loading" callback was only ever a proxy for "the document is parsed", and on macOS 27 the proxy stopped tracking the thing it stands for: measured on a reporter's machine, `document.readyState` read `complete` while `estimatedProgress` sat at 0.10 and `isLoading` stayed true, so the callback never arrived and extraction waited out its whole 10-second timeout. A 100 ms poll now asks the document instead, and the callback stays as the fast path where it works, with a one-shot guard so the two cannot race. Accepting `interactive` as well as `complete` is safe rather than merely convenient: page scripts are disabled and every subresource is refused, so nothing can add to the document after parsing ends. Readiness also requires the DOM to be a plausible size, because a web view starts out holding an empty document that **already reports `complete`**, so the state alone cannot tell a parsed article from one that has not arrived. Real articles measure 62% to 68% of the HTML handed over; an empty document is 39 characters. If the state says complete and the DOM stays tiny for half a second, the load is retried once with blocking off and says so, rather than reporting "no article found", which would be true of that DOM and false of the article.
- On the WebKit rungs the web view **refuses the loads an article references**, via a content rule list that names the resource types to block and deliberately leaves `document` out. It used to be `url-filter: ".*"` with no types, which reads as "block every load", and on macOS 27 that included the article's own HTML: the document arrived empty, so `readyState` reported `complete` for an empty document and Readability correctly found no article in it. The tell was in the timings, where 1.6 MB of HTML and 164 KB both reached `complete` in about 140 ms because neither was being parsed. Naming the types means a document load cannot be caught whatever a future WebKit classifies it as, and it blocks no less well: measured on a 1 MB page with 125 images, 71 scripts and 23 stylesheets, one condition per process, 106 ms against 122 ms for the blanket rule and 855 ms with no rule, and the same 8,161 characters of body text in all three. Handing WebKit a base URL makes it resolve and fetch each image, stylesheet, font, script and beacon the HTML references, and `didFinish` — which extraction waits on — does not fire until all of them settle. One beacon that never answers and it never fires at all. Readability parses structure and needs none of it: measured on three articles, blocking took them to 0.11s, 0.11s and 0.15s from two indefinite stalls and 13.06s, and the DOM came out identical (38,179 characters of body text against 38,178). The base URL still goes in, so relative links in the extracted article resolve; only the fetching is refused. Switchable with `blockSubresources`, which is on by default and should stay on: it exists because a block-everything rule is a blunt instrument, and if a version of macOS ever applied it to the article's own HTML rather than only to the things that HTML references, the page would never finish loading and the symptom would look exactly like the fault the rule cures. One command then tells the two apart.
- **The first extraction of a session self-tests the platform and writes the result to the log.** Four probes each load sixty characters of trivial HTML: `loadHTMLString` into a hosted view with subresource blocking on, the same not suppressed, the same into a view that is in no window at all, and finally the same bytes over a real resource load through a private URL scheme. Sixty characters carries no site, no base URL, no subresources, no encoding and no size, so a probe that fails cannot be failing for any of those reasons. It runs off the critical path and costs the reader nothing. Its purpose is that one log from a machine that cannot open articles says which half of WebKit is unwell, rather than another round of guessing. The first reporter log to carry those probes answered the question and replaced it with a sharper one: `loadHTMLString` is **not** broken on macOS 27, it is broken **above a size**. Sixty characters loaded twelve times out of twelve, while thirteen real reader documents of 8,449 to 17,065 characters all came back as the 39-character empty skeleton, and the same bytes over a real resource load rendered every time. So a fifth probe now **bisects** the range, halving between the sixty characters known to work and 32,768, and states the bracket in one line. It also says which side of that bracket the 511-character video embed host page falls on, because that is what decides whether video plays on an affected Mac. A probe must clear the empty document's own length before a proportion of the payload means anything: at 74 characters the empty skeleton is 39, which passes "at least half of it arrived" and reports a load that never happened.
- **The reader's own display path does not assume `loadHTMLString` worked either.** Having extracted an article, the reader hands the rendered HTML to a web view by exactly the API that is measured dead on macOS 27. It now checks the DOM 1.2 seconds later and, finding it empty, re-serves the identical bytes over the private scheme, and failing that shows the live page. Without this a machine where extraction is fixed would show a blank sheet where it previously showed the real website, which is worse than the fault being repaired.
- Both WebKit views use `WKWebsiteDataStore.nonPersistent()` — no cookies, no local storage, no keychain prompts.
- The Readability reader pane has content JavaScript disabled (`allowsContentJavaScript = false`); it renders static extracted HTML only. The video-embed and live-page web views run JavaScript (a player needs it), still on a non-persistent data store.
- Video plays in-app: YouTube/Vimeo via a chrome-free `<iframe>` host page in `WKWebView`; direct media via `AVKit`'s `AVPlayer`. **The player says whether it loaded.** The host page is a 511-character `<iframe>` wrapper handed to `loadHTMLString`, and this path had no logging, no blank detection and no failure state, so a video that would not play was a white rectangle and complete silence. It now records what was detected — `video: loading YouTube ScuFC5-T2Zc — 511 char host page` — which matters because a wrong or empty video id produces exactly the same blank as a broken player, and after eight seconds without a rendered host page it replaces the empty view with a message and an **Open in Browser** button. That was the fourth place in this app where a missing check turned a failure into a blank pane; the reader, the live page and the PDF view were the others. PDFs render in `PDFKit`. No video or PDF ever bounces you out to a browser.
- Hero images load through a process-wide `ImageCache` that decodes into an `NSCache` and coalesces concurrent requests for a URL onto one in-flight task — so a page turn doesn't re-download, and the lead's prefetch and on-screen view never double-fetch. Pictures are decoded **scaled**, at no more than 2048 pixels on the long edge (`imageMaxPixelSize`), which is what a full-width lead needs on a 2× display: `Paper.maxWidth` less its padding on both sides is 1004 points. `NSImage(data:)` decodes at whatever resolution the source happens to be and holds it, so a 6000-pixel CDN original cost 77.2 MB as a bitmap where the scaled decode costs 9.0 MB, measured on one. Two things guard that. The cap is a ceiling, not a size, so the request is never larger than the file itself: asking 2048 of a 1200-pixel image invites a decoder to answer with something bigger than the file, which saves nothing. And the answer is checked, because macOS 27 treats the request as a point value and multiplies by the display scale, returning 4096 for a request of 2048. Where the answer overshoots, the decode is asked again scaled by the ratio just observed, which needs no knowledge of the display scale that a background thread cannot reliably obtain, and self-corrects on whatever a future decoder does. It costs one extra decode only where the first answer was wrong, and it says so in the log either way, with no silent path.

The log reports the decoded bitmap's own dimensions, and separately says so when those disagree with what the `NSImage` representation reports, because the memory accounting is computed from the representation. Two earlier attempts at this were made on the strength of a log line derived from the representation alone, without either of them ever comparing the two, and both were wrong. Measured on a reporter's machine before this: 38 pictures in one session, every one decoded larger than its own file, 301.5 MB held against a 256 MB limit and 21 evictions. The cache is capped in **bytes** as well as in count, at a thirty-second of physical memory — 256 MB on an 8 GB Mac, 1152 MB on a 36 GB one — because `countLimit` bounds how many pictures are held and says nothing at all about how much memory they take. The cost of a picture is computed from `NSImage.size` and not from its representation: a representation reports pixels scaled by the backing store, so a 1200 × 675 bitmap was charged as 2400 × 1350, four times its real memory. That one wrong number is why two earlier releases tried to fix a decoder that was working correctly, and why an 8 GB Mac read 301.5 MB against its 256 MB limit and evicted 21 pictures when it was really holding 75 MB and needed to evict none.
- Edition composition: dedupe by canonical link, then round-robin across feeds so no source dominates, then lead selection — preferring a story with both a validated picture and a standfirst, falling back through picture, then standfirst, then whatever the paper has — and then 3-column masonry for everything else.

## Building from Source

The build is driven by the shared [`release.mk`](https://github.com/PerpetualBeta/jorvik-release) Make include, so `jorvik-release` has to be checked out **beside this repo** — the Makefile looks for it at `../jorvik-release/`. macOS ships GNU Make 3.81 as `make`, which is too old, so `gmake` comes from [Homebrew](https://brew.sh).

```bash
brew install make   # GNU Make 4+, if you do not already have gmake
git clone https://github.com/PerpetualBeta/jorvik-release.git
git clone https://github.com/PerpetualBeta/JorvikDailyNews.git
cd JorvikDailyNews
gmake build
open.build/JorvikDailyNews.app
```

`gmake build` compiles with `swiftc -O` and ad-hoc-signs for local use. JorvikKit files are compiled in from `JorvikKit/`. Release builds are Developer ID signed and notarized.

To regenerate the app icon (Didot "N" over a dark ink gradient with newspaper masthead rules):

```bash
swift generate_icon.swift
```

## Troubleshooting

### The paper is empty today

Either no feeds have published today yet, or every feed fetch failed (check your internet connection and hit `command` `R`). The today-only filter is strict — items dated before midnight local time don't appear. If you've just added feeds and they don't seem to have today's items, some feeds only publish weekly or less frequently.

**A short post is still a post.** The floor below which a page is judged not to be an article was 500 characters, and that was throwing real writing away. Pairing every thin extraction in a day's log with its link shows a sharp boundary well below it: from 19 to 226 characters the links were product landing pages, Show HN submissions, a Guardian picture page and a video page, with genuinely no article on them; from 258 to 283 they were two Six Colors podcast notes and an iamcal microblog entry, correctly extracted in full. A 283-character post was being rejected, sent to the live page, and reported as an error. The floor is now **250** and it is `minimumArticleLength`, because where a post stops being a post is a judgement and one day of one person's feeds is a small sample.

When there really is no article, the reader says so in those words rather than blaming the renderer. "The reader could not lay this out" is true of a product homepage and useless; what a reader needs to know is that there was never an article there, and that their browser is the way to see the page.

### Readability fails on a site

Paywalled sites, JavaScript-rendered SPAs and some custom CMSes resist extraction. The reader does not dead-end you: it renders the real page inline instead, with **Open in Browser** still in the header as the escape hatch.

### An article won't open

The reader waits 25 seconds at the outside and then shows the real page rather than leaving you on "Turning to the article…". If you are seeing that message persist, turn on diagnostics below and send the log — it will say which step never returned. Two things are worth trying alongside it, each a single command and a relaunch. `defaults write cc.jorviksoftware.JorvikDailyNews showPictures -bool NO` — if articles open with pictures off, the reader is being starved by the picture work rather than failing on its own. And `defaults write cc.jorviksoftware.JorvikDailyNews blockSubresources -bool NO` — if articles open with that off, the content rule list described below is being applied more widely than intended on your version of macOS. `defaults delete` either key to put it back. A third is worth trying if articles never open at all: `defaults write cc.jorviksoftware.JorvikDailyNews readerStrategy loadHTMLString` pins extraction to one named rung of the ladder, and `JavaScriptCore`, `loadSimulatedRequest`, `schemeHandler` and `fileURL` pin the others, so a single command tells apart a fault in one route from a fault in all of them. The log names the rung that won either way.

### Diagnostics

Off by default. To turn it on:

```
defaults write cc.jorviksoftware.JorvikDailyNews debugLogging -bool YES
```

Lines are appended to `~/Library/Logs/Jorvik Daily News/jorvikdailynews.log`, in a directory only you can read. Each run starts with a header recording the app and macOS versions, so the log identifies itself without anyone having to ask. To turn it off again:

```
defaults delete cc.jorviksoftware.JorvikDailyNews debugLogging
```

Every run's second line records the settings actually in force, so a log says which mode produced it rather than leaving that to be guessed:

```
config: pictures ON, maxPixelSize 2048px, cache cap 1152.0 MB on a 36 GB machine, hideReadItems=true
config: subresource blocking ON
```

The reader is instrumented end to end: which branch a link took, the fetch's status and size, each web view callback, whether a timeout fired, what Readability returned, and which fallback was chosen. If you are reporting a problem with opening articles, that log is the thing worth attaching.

**The refresh is instrumented too, and until recently it was not instrumented at all.** A paper that quietly stops filling up is the hardest kind of fault to report, because a quiet news day looks exactly the same. Every refresh now accounts for itself in a few lines:

```
refresh: 242 feeds, 239 ok, 3 failed, 7086 items
refresh: feed failed — carpeaqua.com: Server returned 404
refresh: feed failed — donmelton.com: The certificate for this server is invalid…
refresh: feed failed — www.planet-php.org: Could not parse feed
refresh: carried over 168 from the existing edition
refresh: enriching 423 of 7357 across 27 sections
refresh: published 479 items of 520 eligible from 7522 fetched in 52.6s of 300s allowed
```

A retired feed is reported as retired rather than as unparseable. FeedBurner serves an ordinary web page where a discontinued feed used to be, and an HTML page is usually well-formed enough that `XMLParser` accepts it, so the fetch was recorded as a success that happened to contain no items. A feed that had quietly died therefore looked exactly like a blog nobody had updated, and it never appeared in the failure count at all. A parse that returns a root element other than `rss`, `feed` or `rdf` now says `Served a <html> document, not a feed`, which is a thing to go and fix rather than something to wait out. Malformed markup keeps its own separate message, because the two faults call for different actions.

A parse failure says where and why. `RSSAtomParser` never implemented `parser(_:parseErrorOccurred:)`, so for the whole life of the app "Could not parse feed" was the entirety of what it knew: no line, no column, no reason, and therefore nothing actionable for the only person who could fix it, whoever publishes the feed. It now reports `root <rss>, 4 item(s) built, line 726 col 37: …`, which says how far it got as well as what stopped it.

A feed that breaks partway through keeps what parsed. `XMLParser` reports items to its delegate as it goes, so by the time it hits bad markup the items above the fault are already in hand; returning nothing threw them away. Measured on one subscription: nine items parse cleanly and the parser then dies on an unterminated `<![CDATA[` 726 lines in, so the reader was losing nine good articles to a defect well past them, and the log described the feed as simply dead. An item is only kept once its closing tag is seen, so a half-read item at the point of failure cannot leak through.

Each failing feed gets its own line, sorted so this hour can be compared with the last. The first version of this crammed the names into the summary and capped it at eight, which on a 254-feed subscription list with nineteen failures hid eleven of them, and answering "which ones?" meant fetching all 254 by hand outside the app. A log should not need a second tool. Sorted matters too: the fetches finish in whatever order the network hands them back, and an unstable list cannot be diffed against yesterday's.

Each number answers a different question, which is the point of having four of them. *Feeds ok against feeds failed* catches partial failure: ten dead feeds out of forty used to be completely invisible, because the app only reported an error when every single feed failed, so a morning of them read as a quiet day. *Items fetched against items eligible* is the day filter doing its job, and the gap between them is simply yesterday's news arriving in a feed's rolling window. *Eligible against published* is dedupe and the front page's slot budgets.

Three lines appear only when something is wrong, and each names a distinct fault:

```
refresh: SKIPPED — one is already in flight
refresh: ABANDONED after 300s — it will not publish
refresh: rebuild was EMPTY of 0 eligible — KEPT the STALE edition dated 2026-09-08, 396 items
```

The first two are about a refresh that will not finish. A refresh holds a flag so two cannot overlap, and that flag used to be cleared by the refresh itself, which is only safe if it always finishes. One network call that never returns and the flag stays set for the life of the process, after which every refresh returns immediately and silently: the hourly timer, and the reader's own refresh button. The paper simply stops changing and nothing says so. A refresh now races a clock, the flag is released by whichever finishes first, and an abandoned refresh is cancelled and checks for that before publishing, so a late arrival cannot overwrite an edition built after it.

**Requests are windowed rather than fired all at once.** A refresh used to add one task per feed and one per enrichment candidate, so a 242-feed subscription list put 242 fetches in flight and the enrichment pass added up to 420 more: about 670 concurrent requests, hourly. A GUI app on macOS gets a soft ceiling of 256 file descriptors and this one already holds about 94, so the feed fetch alone was over the line before enrichment started. Sixteen feeds and eight article pages now run at a time, a peak of 24 against 674. Measured across a day of hourly refreshes the cost is real but small, and the spread matters more than the average: 47 to 183 seconds, against the 21 seconds an uncapped fetch took. The 183-second outlier is 61% of the allowance on its own, which is the figure to watch rather than the mean.

That clock is sized from the parts rather than picked. Feeds are fetched concurrently at 20 seconds each and the self-healing path can go round twice, so the fetch is worth 40 seconds on its own; enrichment then fetches article pages at 10 seconds each, and the lead's image is warmed through up to eight candidates. Roughly 90 seconds of worst case, against a measured spread of 47 to 183 seconds on a real subscription list of 242 feeds. The allowance is 300 seconds, and every refresh reports what it used against what it was allowed, because the only way that margin stays honest is if somebody can see it.

The notice itself comes in two forms, because the two failures need opposite advice. A page whose bytes never arrived has nothing to do with macOS, and the first version told the reader it did: "that points at the part of macOS that draws web pages" is a confident wrong answer when a slow server has simply timed out. `spectrum.ieee.org` returns the same 469,053 bytes in anywhere from 5.2 to 13.8 seconds, so the article's own fetch allowance of 10 seconds sat inside that spread and the page succeeded or failed on a coin toss. That allowance is now **12 seconds**, and it is named rather than derived from half the extraction budget, which was a coupling nothing at the call site would have revealed. 12 does not cover the 13.8-second observation, deliberately: a slow host should not be able to hold the reader much longer than that. And the failure is classified on the error type rather than by reading its message, so only a fetch that never completed gets the "would not download" wording.

The third line is about the midnight boundary, and the word `STALE` is the whole message. Keeping the current edition when a rebuild comes back empty is deliberate, and usually means the network is down. Keeping *yesterday's* is a different event: just after midnight nothing has been published yet, so an empty rebuild is correct, and holding the previous edition puts a paper on screen that the app otherwise promises never to show.

Pictures are instrumented too. Each one reports the size it arrived at, the size it was kept at, and the cache's running total against its cap; `SCALED` appears only when the two sizes differ, so a glance says whether the pixel cap is doing anything on your feeds:

```
image: 6000x3375 -> 2048x1152 SCALED 9.0 MB — holding 43.6 MB of 1152.0 MB across 13 — cdn.example.com
image: EVICTED 9.0 MB — holding 34.6 MB of 1152.0 MB across 12
```

A picture that fails now says so. Every log line in the picture path used to be a success: decoded, evicted, decode-corrected. So "this story has no picture" and "this story's picture was refused" were the same event as far as the log was concerned, which is no event at all, and a front page of text-only cards could not be told from a front page of failures. There are now two failure lines and one summary:

```
image: REJECTED cdn.example.com — HTTP 404; not asked again this session
image: FAILED i.example.com — The request timed out; retrying after 60s
enrich: 420 page(s) asked — 96 gained a picture, 31 a standfirst; 284 declare none, 2 offer only their site icon, 7 would not fetch
```

`REJECTED` is a settled fact about the URL and is remembered for the session. `FAILED` gets a cool-off and another try. The enrichment summary is the one that makes a sparse page interpretable, because the interesting number is `declare none`: measured on a Hacker News front page, of twelve stories with no picture **nine of the target pages genuinely declare no `og:image` or `twitter:image` at all**, so the sparse look was mostly honest reporting rather than a fault. Three were misses. Without that split, both look identical.

The source dimensions come from the file's metadata, so reading them costs no decode. `EVICTED` lines are the ones worth counting: a machine that evicts steadily is running against its cap, and a machine that never evicts is not, which is the difference between a memory problem and something else entirely.

When the reader gives up, the log says what the web view was doing rather than only that it stopped:

```
extract: TIMED OUT after 10.0s waiting on the web view (estimatedProgress 0.00, isLoading false, url ...)
extract: post-timeout document.readyState = interactive
```

Those separate three states that look identical from outside. A progress of 0 with `isLoading false` means the load never began. A progress parked near 0.6 means it stuck partway. A `readyState` of `interactive` or `complete` means the page is ready and the finished signal is being withheld. If the second line never appears at all, the web view stopped answering entirely, which is itself the answer.

One line matters more than any of them:

```
webview: WEB CONTENT PROCESS TERMINATED — WebKit's renderer died, so no navigation callback can arrive.
```

WebKit renders pages in a separate process. If that process is killed, usually for memory, no success or failure callback is ever sent. Without this line the app can only report that it waited and gave up, which describes the symptom and hides the cause.

### Images missing from some items

Not every feed ships images, and not every article has an `og:image`. Hacker News items and some text-only blogs won't have thumbnails — the card just shows the headline, which is often fine.

---

Jorvik Daily News is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
