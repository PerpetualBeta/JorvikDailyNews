# Video, PDFs and Awkward Pages

*What happens when an item is not an article: a video, a PDF, a paywall, or a page that builds itself in JavaScript.*

## In-app video

Video links play *inside* the paper, chrome-free, rather than kicking you out to a browser. YouTube and Vimeo render as a borderless embedded player (loaded through a host page so the player sees a legitimate third-party origin — no "Error 152/153"); direct media files (`.mp4`, `.m4v`, `.mov`, `.webm`) play in a native `AVPlayer`.

Most video feeds label their items `[video]` already, but some submitters don't — so any headline whose link plays in-app gets a `[VIDEO]` tag appended automatically when nothing in the title or summary already signals it. You always know you're about to open a video before you click — handy when you're in an office or a library.

## PDFs

A link to a PDF — by extension, or detected by content-type when the URL doesn't end in `.pdf` — opens in a native `PDFKit` view inside the reader, scrollable and zoomable, instead of downloading or bouncing to a browser.

**It reports the size and it can fail out loud.** A 7.4 MB report at 176 KB/s is forty-two seconds of waiting, and "Loading PDF…" for forty-two seconds cannot be told apart from a hang. The download is streamed rather than fetched whole, so the view shows a real progress bar and `2.1 MB of 7.4 MB`, updated five times a second rather than per byte. Before this, a failure was a **white page**: the cover over the PDF view was lifted by a `defer`, whether or not a document had arrived, so a failed download revealed an empty view and said nothing at all. Now a failure shows the same notice the reader uses, with the byte count and the reason, and **Open in Browser** as the way through. The request also has a timeout of its own; it previously had none and inherited `URLSession`'s default with no sign of which it was doing.

## Live page fallback

When Readability can't extract a clean article (paywalls, JavaScript-rendered SPAs, link-list pages), the reader doesn't dead-end you out to a browser: it renders the real page inline in a full web view. **Open in Browser** stays in the header as the escape hatch for anyone who wants it.

**A wrapper page is followed first.** Some pages are a frame around somebody else's document and carry almost no text of their own. `huggingface.co/spaces/…` is 28,153 characters of site chrome holding **50 characters** Readability would call an article, while the piece itself — 62,795 characters, 173 paragraphs, 35 headings — sits in an iframe. That frame is now followed, but only after the page's own content has already failed, so a real article that merely embeds a video or a map is never redirected away from. Players, social embeds, comment widgets and tag managers are refused by host.

**And the cover says what is happening.** The live page loads underneath a notice that counts, because a page can take a long time for honest reasons: one measured site ships a 6 MB JavaScript bundle from a server running at about 175 KB/s, so nothing can appear for 45 seconds. The wait is governed by whether the page is still loading rather than by a stopwatch, since no fixed deadline can tell a slow server from a broken one — but a navigation that has produced *no document at all* after 12 seconds has not started, and that is reported at once rather than after a minute of spinner.

## Feed health

Each feed in Manage Feeds carries a colour dot: green (fetched cleanly and recently), orange (a little stale), red (repeatedly failing or long silent). Paused feeds show no dot — we deliberately stopped fetching them, so a "stale" warning would mislead.

---

[← Back to the README](../README.md)
