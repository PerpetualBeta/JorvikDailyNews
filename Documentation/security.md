# Handling Hostile Content

*Every byte the app parses comes from somewhere it does not control. What was found when the whole surface was reviewed on that assumption, and what was done about it.*

A feed chooses its own XML, the article HTML at whatever it links to, the image and PDF bytes, the `og:` metadata, and every `href` and `src` in the page. You click a headline; there is no other consent step. The whole surface was reviewed on that assumption in September 2026, and what follows is what came out of it rather than a statement of intent.

**The parser cannot be made to execute anything.** LinkeDOM parses and never executes: there is no `eval`, no `new Function`, no string-form `setTimeout` and no dynamic `import()` in any bundled script, event-handler attributes are stored as inert strings, each article gets a fresh `JSContext`, and only two functions are bridged into it.

**One place decides where a request may go.** `WebURL` allows `http` and `https` and nothing else, and refuses loopback, the private ranges, `169.254` (cloud metadata), carrier NAT, IPv6 link-local and unique-local, `::ffff:` mapped IPv4, and the names that only mean something on your own network — including a single-label host, since `http://intranet/` has no dot and resolves through your search domains. It also refuses the legacy IPv4 spellings, which matters more than it sounds: macOS `inet_pton` accepts `0177.0.0.1` and reads it as **177**.0.0.1, while `inet_aton` reads the same string as **127**.0.0.1, which is what a browser connects to. Both readings are consulted. The one gap left is documented in that file: a public hostname whose DNS resolves to a private address, which is a check on the socket rather than on the URL.

Article links get the same rule, and that is why they need it. A `webcal:` link subscribes Calendar to somebody's feed permanently, `smb:` prompts Finder for credentials against their host, `ssh:` hands a command line to a terminal, and `file:///System/Applications/…` launches an application — all on one click, and all drawn identically to a real link. `mailto:` is the exception, and it arrives with a sheet showing the address and naming anything the link tried to smuggle alongside it.

**Every response body has a ceiling**, because `URLSession` obeys none and `timeoutInterval` is an *idle* timeout, so a host dribbling bytes keeps a connection alive while the buffer grows. The numbers come from what the app has actually downloaded: 32 MB for markup against a largest-ever body of 4.97 MB, 256 MB for a document against a largest-ever PDF of 7.44 MB.

**A feed cannot spend your afternoon.** Internal XML entities are allowed — a feed wanting `&nbsp;` must declare one — but a large one is refused before parsing, because libxml2 rescans an entity value at every reference and a 1.5 MB file can cost a minute of CPU. Item counts, titles, summaries, element text and document text are all bounded, and so are the two files that are never day-scoped.

**And a feed cannot name another feed's story.** An item's identity used to be the `guid` it offered, and guids are public, so copying one from a rival's feed with a later timestamp would silently delete the real article before it reached a page. Identities are the guid hashed with the feed's own id now.

**The sandbox is the backstop for what none of that reaches.** PDFKit and AVFoundation are large C parsers handed attacker-chosen bytes in-process, and the routing is extension-driven — a `.pdf` path goes to one and an `.mp4` path to the other, so the attacker picks. No change in this codebase removes that, which is the argument for the container.

---

[← Back to the README](../README.md)
