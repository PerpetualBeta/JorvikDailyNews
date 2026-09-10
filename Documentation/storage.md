# Storage

*What the app keeps, where it keeps it, and what it deliberately does not.*

The app is sandboxed, so everything it stores lives inside its own container:

```
~/Library/Containers/cc.jorviksoftware.JorvikDailyNews/Data/
    Library/Application Support/JorvikDailyNews/
```

Before 1.4.8 it was at `~/Library/Application Support/JorvikDailyNews/`, and your subscriptions, read marks and classifier training are copied across once on the first launch after upgrading. What is in there:

- `feeds.json` — feed list (URL, section, title, pause state)
- `editions/YYYY-MM-DD.json` — one file per published day; the most recent seven days are retained
- `read.json` — opened article IDs, persistent across sessions

**Pictures are cached on disk, and that is the one thing here that persists.** Before this the decoded bitmaps lived in memory only, so every launch re-downloaded every picture: around 350 requests for a full edition, every time, from sites that are mostly small and independent. Measured before the change, the app's URL cache held exactly **one** entry. Pictures now use their own `URLSession` with a 256 MB disk cache, and the log reports the hit rate once per launch so the benefit is a measurement rather than a claim. It reports over the **launch window** rather than the whole session, because that is the only stretch a cache can serve: measured on a real launch, all 14 disk hits arrived within **one second** of start-up and none of the following 76 pictures came from disk at all. A lifetime figure of "14 of 126" is arithmetically true and invites the wrong conclusion, since everything after the launch window is a story that did not exist an hour ago. Those first fourteen are the pictures already on the front page from last time, which is exactly the set that decides whether the paper appears at once or assembles itself while you watch. Its memory capacity is deliberately zero, because the decoded bitmaps are already cached in RAM and a second copy of the compressed bytes would only add pressure to the thing it is meant to protect. Caching follows the CDN's own headers, so a host sending `immutable` will hit almost every time and one sending `no-store` will never be cached, which is its right.

**Expiry is per layer, and the layers disagree.** The decoded bitmaps in memory have no expiry at all and are consulted *before* the disk cache, so the layer with proper HTTP freshness checking sits behind one with none: a CDN serving different bytes at the same address would be caught on revalidation and never get that far. Putting a lifetime on the memory cache would mean re-decoding pictures the CDN would have said were still fresh, which costs more than it saves, so instead the whole picture cache is dropped at the turn of the day, along with the set of URLs known to have failed and the ones in cool-off. An edition lasts a day, and a 404 yesterday is not evidence about today. Adding a correct cache behind an incorrect one does not make the pair correct; matching their granularity does.

The Vision crop spans were the worst of the four: a plain dictionary keyed by URL with no bound and no expiry, so every picture the app ever cropped added an entry for the life of the process and nothing removed one. Two numbers an entry, so the leak was small, but that is the same shape of mistake as setting `countLimit` without `totalCostLimit`. They live in an `NSCache` now, which also gives them up under memory pressure, which is right for a value recomputable from a picture still in hand.

**Being sandboxed also means the app can read nothing outside that container** except what you hand it through a file picker. The migration log says how many files moved.

Being straight about it: this means images from sites whose stories you have opened sit in the container's `Library/Caches/JorvikDailyNews/Images` until they age out. That is pictures, not cookies, local storage or history, and the WebKit stores stay non-persistent as before. It is what every feed reader does, and it is a deliberate exception to "nothing persists" rather than an oversight.

No database. No telemetry. No cloud. No cookies — the reader pane uses ephemeral WebKit data stores that don't persist anything to disk or keychain. Reading an article fetches the article and nothing else. On the default path nothing but `URLSession` touches the network at all, because the HTML is parsed in `JavaScriptCore` with no web view involved; on the WebKit rungs the extractor refuses every subresource the page asks for. Either way its images, fonts, analytics beacons and tracking pixels are never requested.

---

[← Back to the README](../README.md)
