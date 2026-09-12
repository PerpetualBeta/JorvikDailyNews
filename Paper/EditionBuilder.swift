import Foundation

struct EditionBuilder {
    /// How many stories fit on one section page.
    ///
    /// Sixty, against a front page of sixteen plus a lead, so a section page
    /// is a long read rather than an endless one: twenty per column in the
    /// three-column masonry. The number that matters is the one it replaces,
    /// which was unbounded and produced a 505-item page.
    ///
    /// Tunable live, because the right figure is a matter of how it feels to
    /// turn a page and that cannot be settled by arithmetic:
    ///
    ///     defaults write cc.jorviksoftware.JorvikDailyNews sectionPageCap -int 96
    ///
    /// Read with `object(forKey:) as? Int` so an unset key keeps the default:
    /// `integer(forKey:)` answers 0 for a missing key, which here would mean
    /// a page holding nothing.
    static var sectionPageCap: Int {
        let stored = UserDefaults.standard.object(forKey: "sectionPageCap") as? Int
        guard let stored, stored > 0 else { return sectionPageCapDefault }
        return stored
    }
    static let sectionPageCapDefault = 60

    /// The span of local time an edition covers.
    ///
    /// Exposed rather than inlined because a refresh has to report how many of
    /// the items it fetched were even eligible, and deriving that boundary a
    /// second time at the call site would give the app two definitions of
    /// "today" that could drift apart. There is one, and it lives here.
    static func dayRange(for date: Date) -> Range<Date> {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return start..<end
    }

    // Front-page slot budgets, chosen so a quiet day still looks like a paper
    // and a busy day doesn't overfill the front.
    let secondariesCap = 3
    let briefsCap = 12

    /// Most items one day's paper may hold.
    ///
    /// A real subscription list of 242 feeds produces a few thousand in a day.
    /// This is well above that and far below the point where re-encoding the
    /// edition on the main actor is felt.
    static let maxEditionItems = 6000

    /// Keep at most `maxEditionItems`, giving every feed an equal share
    /// before anything competes on date.
    ///
    /// Two passes. The first takes up to `maxEditionItems / feedCount` from
    /// each feed, in date order, so no feed can be evicted by another's
    /// arithmetic. The second fills whatever the quiet feeds left over,
    /// newest-first, so a day with few active sources still fills the paper.
    ///
    /// Re-sorted at the end because everything downstream — `dedupeByLink`
    /// above all, which keeps whichever copy of a syndicated article it meets
    /// first — depends on this list being newest-first.
    /// The publisher a budget is counted against.
    ///
    /// **Not `feedId`, which is one per subscription URL and therefore a
    /// number the attacker chooses.** Both defences keyed on it, and nothing
    /// caps how many subscriptions one host may hold: `OPMLImporter` accepts
    /// 5,000 entries and `FeedStore.importFeeds` appends every non-duplicate,
    /// deduping on the normalised URL, so 5,000 distinct paths on one host are
    /// 5,000 distinct feeds. Measured against a 254-genuine-subscription
    /// fixture: 300 hostile subscriptions of 30 items each took 3,460 of 4,730
    /// slots and all 16 front-page places including the lead; 5,000 of 2 items
    /// each left 254 genuine articles in the whole paper.
    ///
    /// Falls back to the feed id when an item predates `feedHost`, which keeps
    /// an edition saved by an older build working.
    static func publisherKey(_ item: FeedItem) -> String {
        if let host = item.feedHost?.lowercased(), !host.isEmpty { return registrable(host) }
        return item.feedId.uuidString
    }

    static func capped(_ sorted: [FeedItem]) -> [FeedItem] {
        guard sorted.count > maxEditionItems else { return sorted }
        let feeds = Set(sorted.map(publisherKey)).count
        let share = max(1, maxEditionItems / max(1, feeds))
        var taken: [String: Int] = [:]
        var kept: [FeedItem] = []
        var overflow: [FeedItem] = []
        kept.reserveCapacity(maxEditionItems)
        for item in sorted {
            if kept.count >= maxEditionItems { break }
            let key = publisherKey(item)
            let used = taken[key, default: 0]
            if used < share {
                taken[key] = used + 1
                kept.append(item)
            } else {
                overflow.append(item)
            }
        }
        if kept.count < maxEditionItems {
            kept.append(contentsOf: overflow.prefix(maxEditionItems - kept.count))
            kept.sort { $0.publishedAt > $1.publishedAt }
        }
        return kept
    }

    func build(from items: [FeedItem], date: Date) -> Edition {
        // Daily News means: only items whose published date falls inside today
        // (local calendar). Older items never appear, even if they'd otherwise
        // rank highly — hence "Daily". Refreshes during the day pick up new
        // today-items as they publish.
        let today = Self.dayRange(for: date)
        let todayOnly = items.filter { today.contains($0.publishedAt) }
        // Sort BEFORE deduping, not after. `dedupeByLink` keeps whichever
        // copy it meets first, so the order it is handed decides which of two
        // syndicated copies reaches the page — and un-sorted, that order is
        // the completion order of 16 concurrent fetches, which is a race.
        // Two feeds carrying one article (Guardian main + Guardian football)
        // could therefore yield a different paper on each refresh, and the
        // copies are not interchangeable: one may have been enriched with a
        // picture and a standfirst and the other not.
        //
        // Sorted first, "first seen" means "newest", every time.
        let sorted = todayOnly.sorted { $0.publishedAt > $1.publishedAt }
        // Dedupe by canonical link, then by itemId as a fallback for feeds
        // that share guids but not URLs.
        // **A ceiling on the whole edition.**
        //
        // `performRefresh` carries forward every prior-edition item still
        // belonging to a subscribed feed, with no cap, and nothing downstream
        // imposes one: oversized sections are paginated rather than truncated,
        // and `dedupeByLink` collapses only identical links or itemIds — both
        // of which a feed chooses. So a feed serving 500 items an hour with a
        // fresh `?r=` on each link grows the edition all day, and the whole
        // thing is re-encoded pretty-printed on the main actor at every refresh
        // and decoded on the main actor at launch before any window exists.
        //
        // Day-keyed storage makes it self-limiting by midnight, which bounds
        // the damage rather than preventing it.
        //
        // Sorted newest-first already, so truncating keeps the newest — which
        // is what a paper wants anyway.
        //
        // **Newest is not the same as trustworthy.** Taking a plain prefix
        // evicts by `publishedAt`, and `publishedAt` is a string the feed
        // wrote. One feed serving its per-fetch maximum of 500 items, each
        // stamped at the top of the allowed range, sorts above every honestly
        // dated item in the paper and spends the whole 6,000 on itself — and
        // this runs BEFORE `dedupeByLink` and `roundRobinByFeed`, so the
        // per-feed diversity that would otherwise limit one source never sees
        // the items that were dropped. `performRefresh` carries the survivors
        // forward each hour, so the saved edition converges on that feed and
        // the reader's own subscriptions stop appearing.
        //
        // So the budget is per feed first and global second.
        let capped = Self.capped(sorted)
        if capped.count < sorted.count {
            jdnLog("edition: \(sorted.count) items is over the \(Self.maxEditionItems) "
                   + "allowed — kept the newest \(capped.count)")
        }
        let deduped = dedupeByLink(capped)
        let interleaved = roundRobinByFeed(deduped)

        // The lead *must* display an image — a text-only hero looks like a
        // mistake at full-width span. An item qualifies only if it has an
        // image URL that isn't already known to have failed to load (a 404'd
        // og:image, a dead host, etc. — `ImageCache` records these as they
        // fail at render). Round-robin biases ordering by recency + diversity,
        // so `.first(where:)` picks the newest usable-image item from the
        // strongest feed. If none qualify, drop the lead entirely (lead = nil)
        // and let every item flow into the 3 columns instead.
        var remaining = interleaved
        // Prefer an item that can carry BOTH halves of a lead, then either half,
        // then anything at all. The front page always has a lead now.
        //
        // It used to fall to nil when nothing had a usable picture, on the
        // grounds that a text-only hero looks like a mistake at full-width
        // span. That was true when the alternative was a bare headline over
        // white space. It is no longer: a lead with no picture is now a
        // full-width headline over a two-column deck, which reads as a paper
        // with no art today rather than as something that failed.
        //
        // Dropping the lead was also the wrong failure mode for the reason it
        // usually fired. `hasUsableImage` consults `ImageCache`, so a moment of
        // throttling that marks pictures unusable took the whole lead with it
        // and left a front page that opened on a column of small headlines.
        // Losing the picture is a fair consequence of a bad cache. Losing the
        // lead is not.
        let candidate = remaining.first(where: { Self.canAnchorLead($0) })
            ?? remaining.first(where: { Self.hasUsableImage($0) })
            ?? remaining.first(where: { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? remaining.first
        let lead: FeedItem?
        if let candidate, let idx = remaining.firstIndex(of: candidate) {
            lead = candidate
            remaining.remove(at: idx)
        } else {
            // Only when there is nothing in the paper at all.
            lead = nil
        }

        let secondaries = Array(remaining.prefix(secondariesCap))
        remaining = Array(remaining.dropFirst(secondaries.count))
        let briefs = Array(remaining.prefix(briefsCap))
        remaining = Array(remaining.dropFirst(briefs.count))
        let leftover = remaining
        let bySection = Dictionary(grouping: leftover) { $0.section }
        // A section page used to be "everything left over", with no cap, so a
        // busy News section put **505 items on one page**. Every card in the
        // masonry publishes its height through a `GeometryReader` and every
        // height change triggers a redistribute, so 505 of them is a
        // measure-and-relayout storm on the main thread: the page took
        // seconds to open and spun the beachball while it did.
        //
        // A newspaper page has an extent. An oversized section becomes several
        // pages of the same name, which the page title renders as
        // "News (2 of 9)", and which is what a broadsheet does anyway.
        let sections = bySection
            .map { (name: $0.key, items: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .flatMap { section -> [SectionPage] in
                stride(from: 0, to: section.items.count, by: Self.sectionPageCap).map { start in
                    let end = min(start + Self.sectionPageCap, section.items.count)
                    let page = Array(section.items[start..<end])
                    return SectionPage(name: section.name, items: page,
                                       repeatedPictures: PagePictures.repeats(in: page,
                                                                              signature: Self.signature))
                }
            }

        // The front page is one page for this purpose: the lead and the cards
        // under it are all in view together.
        let front = (lead.map { [$0] } ?? []) + secondaries + briefs

        return Edition(
            date: Calendar.current.startOfDay(for: date),
            publishedAt: Date(),
            lead: lead,
            secondaries: secondaries,
            briefs: briefs,
            sections: sections,
            repeatedPictures: PagePictures.repeats(in: front, signature: Self.signature)
        )
    }

    /// An item can anchor the full-width lead only if it has an image URL we
    /// haven't already seen fail to load (`ImageCache` records failures as
    /// they happen at render). A merely-slow image still qualifies — only a
    /// confirmed failure disqualifies it.
    /// An item fit to anchor the lead: a usable picture and something to read
    /// under the headline.
    static func canAnchorLead(_ item: FeedItem) -> Bool {
        hasUsableImage(item) && !item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where a picture's fingerprint comes from, as one named seam.
    ///
    /// A `var` so a test can replace it. `PagePictures` takes the lookup as an
    /// argument for the same reason, and this is the only place that reaches
    /// for the real store.
    nonisolated(unsafe) static var signature: (URL) -> PictureSignature? = {
        PictureSignatureStore.shared.signature(for: $0)
    }

    static func hasUsableImage(_ item: FeedItem) -> Bool {
        guard let url = item.imageURL else { return false }
        if ImageCache.shared.isFailed(url) { return false }
        // Known from a previous sighting to have nothing in it. `ImageCache`
        // catches this the first time a blank is decoded, but only for that
        // session; the fingerprint outlives the launch, so from the second
        // sighting on a blank never reaches the lead slot at all.
        if let signature = Self.signature(url), signature.isFeatureless { return false }
        return true
    }

    /// Remove items that share a canonical link or itemId with an earlier
    /// item, preserving the order given.
    ///
    /// First seen wins, so the caller's ordering IS the tie-break rule. It is
    /// handed a date-sorted list for exactly that reason.
    /// Public suffixes of two labels, so `bbc.co.uk` is not read as `co.uk`.
    ///
    /// A short list rather than the full Public Suffix List, which is 10,000
    /// lines that change monthly. Getting one wrong costs a comparison that
    /// declines to prefer, or one that treats two hosts under the same
    /// registrar's suffix as the same publisher — and reaching that second
    /// case needs a feed the reader subscribed to by hand.
    static let twoLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "sch.uk",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "net.nz", "org.nz", "govt.nz",
        "com.br", "com.mx", "com.ar", "com.sg", "com.hk", "com.tw", "com.tr",
        "co.za", "co.in", "co.kr", "co.il", "co.id", "co.th"
    ]

    /// Suffixes where the second label is a hosting platform, not a
    /// publisher.
    ///
    /// **Without these, every tenant of one platform read as the same
    /// publisher.** Measured against the shipped file:
    /// `registrable("attacker.substack.com")` and
    /// `registrable("victim.substack.com")` both gave `substack.com`, and the
    /// same for github.io, blogspot.com, wordpress.com, medium.com, pages.dev,
    /// netlify.app and amazonaws.com — so an attacker's Substack satisfied
    /// `publishesItsOwn` against another Substack's links, and the log
    /// recorded the substitution as a legitimate preference.
    ///
    /// The old comment said reaching that "needs a feed the reader subscribed
    /// to by hand". Every feed in this app arrives by hand, so that clause
    /// excluded nothing, and hand-subscribed Substacks are exactly the feeds
    /// in question.
    static let multiTenantSuffixes: Set<String> = [
        "substack.com", "github.io", "gitlab.io", "blogspot.com", "wordpress.com",
        "medium.com", "tumblr.com", "pages.dev", "workers.dev", "netlify.app",
        "vercel.app", "web.app", "firebaseapp.com", "herokuapp.com",
        "azurewebsites.net", "cloudfront.net", "amazonaws.com", "appspot.com",
        "ghost.io", "bearblog.dev", "micro.blog", "neocities.org", "sourceforge.net",
        "readthedocs.io", "notion.site", "typepad.com", "livejournal.com",
    ]

    /// The registrable part of a host: `www.bbc.co.uk` and `feeds.bbc.co.uk`
    /// both give `bbc.co.uk`.
    static func registrable(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let pair = labels.suffix(2).joined(separator: ".")
        var wanted = twoLabelSuffixes.contains(pair) || multiTenantSuffixes.contains(pair) ? 3 : 2
        if wanted == 3, labels.count > 3 {
            // A ccTLD suffix that is ALSO multi-tenant, e.g. a.b.co.uk, needs
            // one more label still.
            let triple = labels.suffix(3).joined(separator: ".")
            if multiTenantSuffixes.contains(triple) { wanted = 4 }
        }
        guard labels.count >= wanted else { return host }
        return labels.suffix(wanted).joined(separator: ".")
    }

    /// Whether this item came from a feed on the same domain as its own link.
    ///
    /// **Both sides of this test used to be attacker-supplied.** It compared
    /// the link's host against `item.sourceTitle` — the feed's own declared
    /// channel title, which `AppStore` overwrites from the fetched XML on every
    /// refresh — so a feed could call itself "BBC News", copy the BBC's links
    /// verbatim, and satisfy a test whose comment said it could not be
    /// satisfied "without controlling the domain they are impersonating".
    ///
    /// It was also reading the wrong label. `dropLast().last` takes the
    /// second-to-last, so `www.bbc.co.uk`, `feeds.bbc.co.uk` and `bbc.co.uk`
    /// all gave `co`, which fails the three-character minimum — the guard
    /// never fired for any `.co.uk`, `.com.au` or `.co.jp` host, nor for
    /// `ft.com`. The comment above it said "the registrable-ish tail".
    ///
    /// `feedHost` is the host of the subscription the reader added, which is
    /// the one string on the item no feed can choose. Comparing it against the
    /// link's host is the check the old comment already claimed. Still
    /// one-directional: it can only PREFER an item, never drop one, so an
    /// edition saved before `feedHost` existed simply declines to prefer.
    static func publishesItsOwn(_ item: FeedItem) -> Bool {
        guard let feedHost = item.feedHost?.lowercased(), !feedHost.isEmpty,
              let linkHost = item.link.host?.lowercased() else { return false }
        return registrable(feedHost) == registrable(linkHost)
    }

    private func dedupeByLink(_ items: [FeedItem]) -> [FeedItem] {
        var seenLinks = Set<String>()
        var seenIds = Set<String>()
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        // **A link collision is decided by who is publishing it, not by who
        // dated it latest.** First-met wins, and the list is sorted strictly
        // newest-first, so a feed copying another outlet's links and dating
        // them to the end of today took every collision and the genuine item
        // vanished with no error and no log line.
        //
        // Dating is clamped at the fetcher now, but a copy timed to arrive
        // seconds after the original would still win. So an item whose
        // SUBSCRIPTION host matches its link's host is preferred: a
        // publisher's feed points at its own articles, and an attacker cannot
        // arrange that without the reader having subscribed to a feed on the
        // domain being impersonated.
        //
        // **What that does NOT cover, stated rather than claimed away.** The
        // premise "a publisher's feed points at its own articles" fails for
        // every feed-host-served publication, and that is the common case, not
        // the exception. Measured against this reader's own saved edition: of
        // 60 items, 8 would satisfy `publishesItsOwn` and 52 would not —
        // hnrss.org to ycombinator.com, feedpress.me to sixcolors.com,
        // medium.com, substack.com, github.com and the rest. The app
        // manufactures the mismatch itself, because `resolveTargetURL`
        // replaces an aggregator's discussion URL with the external target by
        // design.
        //
        // When neither side can be shown to publish the link, nothing swaps
        // and first-met wins, which means the date decides. That is why the
        // date clamp is measured against the feed's own previous successful
        // fetch rather than against `now`: a feed cannot restamp itself to the
        // present on every refresh any more, so an honestly dated item
        // published since that fetch still sorts above a copy. The residual is
        // the first refresh after the reader subscribes to a feed, when there
        // is no previous fetch to clamp against — which requires the reader to
        // have just added the attacker's feed by hand.
        var winners: [String: FeedItem] = [:]
        var order: [String] = []
        for item in items {
            let linkKey = item.link.absoluteString.lowercased()
            if seenIds.contains(item.itemId) { continue }
            seenIds.insert(item.itemId)
            guard let held = winners[linkKey] else {
                winners[linkKey] = item
                order.append(linkKey)
                continue
            }
            // Held item stays unless the newcomer is the link's own publisher
            // and the held one is not.
            if Self.publishesItsOwn(item), !Self.publishesItsOwn(held) {
                jdnLog("edition: \(item.sourceTitle) publishes \(item.link.host ?? "?") itself — "
                       + "preferred over \(held.sourceTitle) for the same link")
                winners[linkKey] = item
            }
        }
        for key in order {
            if let item = winners[key] {
                seenLinks.insert(key)
                result.append(item)
            }
        }
        return result
    }

    /// Round-robin across feeds so no single source dominates the front page.
    /// Feed order is seeded by first-seen (i.e. whichever feed has the newest
    /// item goes first); within each feed, items stay in date-desc order.
    private func roundRobinByFeed(_ items: [FeedItem]) -> [FeedItem] {
        // Keyed on the publisher, not the subscription. See `publisherKey`:
        // `order` is seeded by first appearance across the whole list, so with
        // one bucket per subscription the front page was the first sixteen of
        // a list an attacker holding most of the feed ids mostly owned.
        var buckets: [String: [FeedItem]] = [:]
        var order: [String] = []
        for item in items {
            let key = Self.publisherKey(item)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]!.append(item)
        }

        // Walked with an index rather than rebuilt.
        //
        // `buckets[feedId] = Array(bucket.dropFirst())` copied the whole
        // remaining bucket on every single take, so one bucket of N cost about
        // N squared over 2 `FeedItem` copies — on the main actor, several times
        // per refresh and again on every filter toggle. At a few hundred items
        // it is invisible; it is the accumulation in `build` that could have
        // made it matter.
        var taken: [String: Int] = [:]
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        var placed = 0
        while placed < items.count {
            for feedId in order {
                let index = taken[feedId, default: 0]
                guard let bucket = buckets[feedId], index < bucket.count else { continue }
                result.append(bucket[index])
                taken[feedId] = index + 1
                placed += 1
            }
        }
        return result
    }
}
