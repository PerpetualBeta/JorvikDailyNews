# Troubleshooting

*An empty paper, an article that will not open, a missing picture — and the diagnostics that tell you which of those you actually have.*

## The paper is empty today

Either no feeds have published today yet, or every feed fetch failed (check your internet connection and hit `command` `R`). The today-only filter is strict — items dated before midnight local time don't appear. If you've just added feeds and they don't seem to have today's items, some feeds only publish weekly or less frequently.

**A short post is still a post.** The floor below which a page is judged not to be an article was 500 characters, and that was throwing real writing away. Pairing every thin extraction in a day's log with its link shows a sharp boundary well below it: from 19 to 226 characters the links were product landing pages, Show HN submissions, a Guardian picture page and a video page, with genuinely no article on them; from 258 to 283 they were two Six Colors podcast notes and an iamcal microblog entry, correctly extracted in full. A 283-character post was being rejected, sent to the live page, and reported as an error. The floor is now **250** and it is `minimumArticleLength`, because where a post stops being a post is a judgement and one day of one person's feeds is a small sample.

When there really is no article, the reader says so in those words rather than blaming the renderer. "The reader could not lay this out" is true of a product homepage and useless; what a reader needs to know is that there was never an article there, and that their browser is the way to see the page.

## Readability fails on a site

Paywalled sites, JavaScript-rendered SPAs and some custom CMSes resist extraction. The reader does not dead-end you: it renders the real page inline instead, with **Open in Browser** still in the header as the escape hatch.

## An article won't open

The reader waits 25 seconds at the outside and then shows the real page rather than leaving you on "Turning to the article…". If you are seeing that message persist, turn on diagnostics below and send the log — it will say which step never returned. Two things are worth trying alongside it, each a single command and a relaunch. `defaults write cc.jorviksoftware.JorvikDailyNews showPictures -bool NO` — if articles open with pictures off, the reader is being starved by the picture work rather than failing on its own. And `defaults write cc.jorviksoftware.JorvikDailyNews blockSubresources -bool NO` — if articles open with that off, the content rule list described below is being applied more widely than intended on your version of macOS. `defaults delete` either key to put it back. A third is worth trying if articles never open at all: `defaults write cc.jorviksoftware.JorvikDailyNews readerStrategy loadHTMLString` pins extraction to one named rung of the ladder, and `JavaScriptCore`, `loadSimulatedRequest`, `schemeHandler` and `fileURL` pin the others, so a single command tells apart a fault in one route from a fault in all of them. The log names the rung that won either way.

## Diagnostics

Off by default. To turn it on:

```
defaults write cc.jorviksoftware.JorvikDailyNews debugLogging -bool YES
```

Lines are appended to

```
~/Library/Containers/cc.jorviksoftware.JorvikDailyNews/Data/Library/Logs/Jorvik Daily News/jorvikdailynews.log
```

in a directory only you can read. It is inside the container because the app is sandboxed; before 1.4.9 it was at `~/Library/Logs/Jorvik Daily News/`, and a log from an older build will still be there. Each run starts with a header recording the app and macOS versions, so the log identifies itself without anyone having to ask. To turn it off again:

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

## Images missing from some items

Not every feed ships images, and not every article has an `og:image`. Hacker News items and some text-only blogs won't have thumbnails — the card just shows the headline, which is often fine.

---

Jorvik Daily News is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).

---

[← Back to the README](../README.md)
