# Handling Hostile Content

*Every byte the app parses comes from somewhere it does not control. What was found when the whole surface was reviewed on that assumption, and what was done about it.*

A feed chooses its own XML, the article HTML at whatever it links to, the image and PDF bytes, the `og:` metadata, and every `href` and `src` in the page. You click a headline; there is no other consent step. The whole surface was reviewed on that assumption in September 2026, and what follows is what came out of it rather than a statement of intent.

**The parser cannot be made to execute anything.** LinkeDOM parses and never executes: there is no `eval`, no `new Function`, no string-form `setTimeout` and no dynamic `import()` in any bundled script, event-handler attributes are stored as inert strings, each article gets a fresh `JSContext`, and only two functions are bridged into it.

**One place decides where a request may go.** `WebURL` allows `http` and `https` and nothing else, and refuses loopback, the private ranges, `169.254` (cloud metadata), carrier NAT, IPv6 link-local and unique-local, `::ffff:` mapped IPv4, and the names that only mean something on your own network — including a single-label host, since `http://intranet/` has no dot and resolves through your search domains. It also refuses the legacy IPv4 spellings, which matters more than it sounds: macOS `inet_pton` accepts `0177.0.0.1` and reads it as **177**.0.0.1, while `inet_aton` reads the same string as **127**.0.0.1, which is what a browser connects to. Both readings are consulted. The one gap left is documented in that file: a public hostname whose DNS resolves to a private address, which is a check on the socket rather than on the URL.

Article links get the same rule, and that is why they need it. A `webcal:` link subscribes Calendar to somebody's feed permanently, `smb:` prompts Finder for credentials against their host, `ssh:` hands a command line to a terminal, and `file:///System/Applications/…` launches an application — all on one click, and all drawn identically to a real link. `mailto:` is the exception, and it arrives with a sheet showing the address and naming anything the link tried to smuggle alongside it.

**Every response body has a ceiling**, because `URLSession` obeys none and `timeoutInterval` is an *idle* timeout, so a host dribbling bytes keeps a connection alive while the buffer grows. The numbers come from what the app has actually downloaded: 32 MB for markup against a largest-ever body of 4.97 MB, 256 MB for a document against a largest-ever PDF of 7.44 MB.

**A feed cannot spend your afternoon.** Internal XML entities are allowed — a feed wanting `&nbsp;` must declare one — but a large one is refused before parsing, because libxml2 rescans an entity value at every reference and a 1.5 MB file can cost a minute of CPU. Item counts, titles, summaries, element text and document text are all bounded, and so are the two files that are never day-scoped.

**And a feed cannot name another feed's story.** An item's identity used to be the `guid` it offered, and guids are public, so copying one from a rival's feed with a later timestamp would silently delete the real article before it reached a page. Identities are the guid hashed with the feed's own id now.

**PDFKit is not in this process.** A feed controls the bytes of a linked PDF and also chooses that PDFKit is what parses them, because routing is extension-driven. PDFKit is a large C parser with a long CVE history, and it used to run in the app, one click from a headline. It now runs in a helper at `Contents/XPCServices/PDFService.xpc` whose entire entitlement list is `com.apple.security.app-sandbox` — no network, no file access, no user data, against the app's five. The app fetches and caps the bytes, writes them to a file in its own container, unlinks the path immediately and hands the helper the read descriptor; back come page sizes, images and plain text, never a parsed document. The isolation is structural rather than promised: the app does not link PDFKit at all, so an edit that reintroduces an in-process parse fails to compile. It costs the text selection and find bar that `PDFView` provided, because both need the document in this process.

**A `.pdf` path that serves a web page goes back to the extractor.** Trusting the extension is a fine fast path and a poor verdict: GitHub's `…/blob/…/report.pdf` is a page that *displays* a PDF. The bytes decide, and the `%PDF` magic number overrules the header, so a real PDF mislabelled `text/html` is still read as one. A vague type is not evidence of HTML either — `raw.githubusercontent.com` sends `application/octet-stream` for a genuine PDF.

**An inline SVG cannot reach outside itself.** SVG is drawn by `NSImage(data:)`, which uses AppKit's private SVG representation: closed code, so what it will resolve is a property of the OS rather than of this app, and it was only ever measured on one version. Scripts, `foreignObject`, iframes, event handlers, stylesheet imports, and any reference or `url()` carrying a scheme other than `data:` are stripped when the block is captured, so the question no longer depends on the OS. Fragment references survive, because `<use href="#icon">` is how real diagrams are built. The reader checks again before drawing, because the stripping is done in JavaScript and the drawing in Swift, and a rule held in only one half is one edit from being gone.

**The sandbox remains the backstop.** AVFoundation still parses attacker-chosen bytes in this process: `AVPlayer` renders through a view and cannot be moved out of it, so the helper approach does not apply. An `.mp4` path still goes straight to it, which is the argument for the container.

---

[← Back to the README](../README.md)
