# Building from Source

*The build, the test suite, and how updates are delivered.*

The build is driven by the shared [`release.mk`](https://github.com/PerpetualBeta/jorvik-release) Make include, so `jorvik-release` has to be checked out **beside this repo** — the Makefile looks for it at `../jorvik-release/`. macOS ships GNU Make 3.81 as `make`, which is too old, so `gmake` comes from [Homebrew](https://brew.sh).

```bash
brew install make   # GNU Make 4+, if you do not already have gmake
git clone https://github.com/PerpetualBeta/jorvik-release.git
git clone https://github.com/PerpetualBeta/JorvikDailyNews.git
cd JorvikDailyNews
gmake build
open .build/JorvikDailyNews.app
gmake test         # the suite; size and rationale below
```

`gmake build` compiles with `swiftc -O` and ad-hoc-signs for local use. JorvikKit files are compiled in from `JorvikKit/`. Release builds are Developer ID signed and notarized.

`gmake test` runs the suite: **634 checks across 162 suites**. Not XCTest and not `swift test` — this app is one `swiftc` binary with no Xcode project and no `Package.swift`, so `Tests/` is an ordinary executable that asserts and exits non-zero, which is all a human or a CI runner needs. It compiles the model layer plus the harness; the views are excluded because nothing in them is testable without a screen.

It covers the parts that fail silently: feed parsing from bytes, the block walker (run as the real `Resources/ReaderBlocks.js` through `JavaScriptCore`, so what is tested is the file that ships), URL and scheme handling, `mailto:` decomposition, the edition builder, entity decoding, standfirst extraction, picture fingerprinting and the day rollover. Every one of those suites exists because something in it was wrong: **the first run of the test target found a bug** — the edition builder deduped before it sorted, so which of two syndicated copies of a story reached the page was decided by the completion order of 16 concurrent fetches.

To regenerate the app icon (Didot "N" over a dark ink gradient with newspaper masthead rules):

```bash
swift tools/generate_icon.swift
```

## Updates

Updates are handled by [Sparkle](https://sparkle-project.org). The app checks for new versions automatically once a day in the background; **Jorvik Daily News → Check for Updates…** runs an on-demand check.

---

[← Back to the README](../README.md)
