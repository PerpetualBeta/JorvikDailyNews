# Jorvik Daily News

A macOS RSS reader that prints a daily newspaper. The app freezes a dated edition on the first launch of each day and you read it like a paper: finite, printed, put down.

## Requirements

- macOS 14 (Sonoma) or later
- Any RSS or Atom feed URLs you want to read

## Why

RSS readers are streams. Streams never end. You open the reader, scroll past the same headlines you already ignored, and close it again no better informed.

A newspaper is the other shape. It publishes once, it is finite, you finish it. This app takes your feeds and uses them to print one paper a day — a composed front page with a lead story, secondaries, and a column of briefs. When there is more news, the paper grows into inside pages. When there is less, it's a thin paper.

## How It Works

On the first launch of a given local day, the app fetches every feed and composes an edition. The result is frozen: returning to the app the same day shows the same paper. Tomorrow it prints a new one.

There is no unread count, no badge, no infinite scroll. You read the paper and close the app.

Click any headline to open the article in your browser. A styled reader pane lands in a later release.

## Using It

| Action | Shortcut |
|---|---|
| Add a feed | `⌘N` |
| Refresh feeds and republish today | `⌘R` |
| About | Apple menu → About Jorvik Daily News |

### Adding a feed

`⌘N` → paste a **feed URL or a site's home page** → choose a section (News, Tech, Culture, …) → Add. New feeds are published into the current day's edition immediately.

The app auto-discovers feeds: paste `https://arstechnica.com` and it will find the feed via `<link rel="alternate">` in the page head. If the page declares no feed, common paths (`/feed`, `/rss`, `/atom.xml`, …) are probed as a fallback.

Sections become inside pages when the edition grows beyond the front page (v0.2+).

## Storage

Everything lives under `~/Library/Application Support/JorvikDailyNews/`:

- `feeds.json` — your feed list and per-feed state
- `editions/YYYY-MM-DD.json` — one file per published day; kept forever

No database. No telemetry. No cloud.

## Technical Details

- Pure Swift + SwiftUI. `swiftc -O` single-binary build — no Xcode project required.
- Feed parsing via Foundation's `XMLParser`. RSS 2.0 and Atom 1.0. No third-party feed library.
- Edition composition is naive-by-design in v0.1: items sorted by publish date; first into the lead slot, next three into secondaries, next eight into briefs.

## Building from Source

```bash
git clone https://github.com/PerpetualBeta/JorvikDailyNews.git
cd JorvikDailyNews
bash build.sh
open JorvikDailyNews.app
```

`build.sh` compiles with `swiftc -O` and ad-hoc-signs for local use. JorvikKit files are compiled in from `JorvikKit/`. Release Manager handles Developer ID signing and notarization for release builds.

## Roadmap

- **v0.1** (this release) — daily edition, front page only, click opens browser
- **v0.2** — multi-page broadsheet (section pages), `⌘←`/`⌘→` page turn, archive browser
- **v0.3** — Readable extract reader pane, image thumbnails on stories, masthead polish
- **v0.4** (maybe) — TextKit 2 flowing body previews on section pages, back-issue search

## Relationship to Other Jorvik Tools

- **Notes Editor** — authors for the jorviksoftware.cc blog. Jorvik Daily News reads blogs; Notes Editor writes one.

---

Jorvik Daily News is provided by [Jorvik Software](https://jorviksoftware.cc/). Public Domain — do whatever you like with it.
