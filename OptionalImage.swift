import SwiftUI
import AppKit

/// Height caps for pictures on the paper, and the `defaults` keys that
/// override them on a running build.
///
///     defaults write cc.jorviksoftware.JorvikDailyNews leadHeroMaxHeight -float 400
///     defaults write cc.jorviksoftware.JorvikDailyNews cardImageMaxHeight -float 300
///     defaults delete cc.jorviksoftware.JorvikDailyNews leadHeroMaxHeight
///
/// A value of 0 or less means "no cap" — the picture runs to its natural
/// height, which is what the paper did before these caps existed.
enum ImageCap {
    /// The lead picture must not push its own headline below the fold at the
    /// smallest window we allow. `minHeight: 700` in `JorvikDailyNewsApp.swift`
    /// is CONTENT height — the window itself measures 752 there, title bar
    /// included — so 700pt is what the paper actually gets. Masthead, rules
    /// and padding take roughly 200pt of that before the picture starts; the
    /// source strap and a two-line Didot headline take roughly 120pt after
    /// it. That leaves about 380pt, and 320 keeps a margin for a headline
    /// that runs to three lines. Verified by screenshot at 900x752.
    static let leadDefault: Double = 320

    /// Cards sit three to a row, so a column is about 316pt wide at the
    /// widest page. Capping just under the column width keeps a portrait
    /// picture reading as a photograph rather than a full-height panel.
    static let cardDefault: Double = 260

    static let leadKey = "leadHeroMaxHeight"
    static let cardKey = "cardImageMaxHeight"

    /// Turns a stored knob value into a cap, treating 0 and negatives as off.
    static func resolve(_ value: Double) -> CGFloat? {
        value > 0 ? CGFloat(value) : nil
    }

    // The views read these knobs through `@AppStorage` so a `defaults write`
    // re-renders them live. These two are for code that isn't a View — the
    // masonry's height estimator — and read the same keys.

    static var lead: CGFloat? { effective(leadKey, fallback: leadDefault) }
    static var card: CGFloat? { effective(cardKey, fallback: cardDefault) }

    private static func effective(_ key: String, fallback: Double) -> CGFloat? {
        // `object(forKey:)` rather than `double(forKey:)`: an ABSENT key must
        // mean "use the default", but `double(forKey:)` returns 0 for absent,
        // which `resolve` reads as "no cap".
        let stored = UserDefaults.standard.object(forKey: key) as? Double
        return resolve(stored ?? fallback)
    }
}

/// Image view that fetches via URLSession and COLLAPSES on failure —
/// unlike AsyncImage which keeps its frame even when the load fails or the
/// URL resolves to a tiny/blank tracking pixel.
///
/// Sizing has two rules, applied in order:
///
/// 1. NEVER UPSCALE. A picture is drawn at most at its own pixel size.
///    Blowing a 512px site icon up to a 1004pt column is 4x of blur, and
///    cropping that to the cap leaves a meaningless slab of flat colour with
///    none of the subject in it. Undersized pictures are drawn small, sharp
///    and centred instead.
/// 2. Then cap the height. A picture still taller than `maxHeight` is cropped
///    to it — around the SUBJECT, using Vision saliency (`SaliencyCache`),
///    falling back to a top-aligned crop when Vision finds nothing.
///
/// `maxHeight: nil` means no cap at all.
///
/// The picture is drawn in an `overlay` on a box that only ever takes the
/// width its column offers. That matters: an `overlay` cannot change its
/// parent's size, so a picture wider than the column can never widen the
/// column. An earlier version put an explicit `.frame(width:)` on the image
/// itself and the masonry collapsed — the image demanded its native width,
/// the HStack granted it, and the width probe below then measured the
/// inflated column and fed it back in.
struct OptionalImage: View {
    let url: URL
    let maxHeight: CGFloat?
    /// Called when the image fails to load (bad URL, non-2xx, undecodable, or
    /// tracker-sized). The lead uses this to demote itself when its image
    /// can't be shown; ordinary cards leave it nil and just collapse.
    let onFailure: (() -> Void)?

    @Environment(\.displayScale) private var displayScale

    @State private var state: LoadState
    /// The column's width, measured. Whether a picture breaches the cap
    /// depends on how wide the column is, and that changes as the window
    /// resizes.
    @State private var width: CGFloat = 0
    /// Vertical centre of the picture's salient region, normalised, in Vision
    /// coordinates (origin bottom-left). Nil until Vision has run, or when it
    /// found nothing worth centring on — either way we crop from the top.
    @State private var salientY: CGFloat?

    init(url: URL, maxHeight: CGFloat? = nil, onFailure: (() -> Void)? = nil) {
        self.url = url
        self.maxHeight = maxHeight
        self.onFailure = onFailure
        // Seed from the cache synchronously so a cached image renders on the
        // very first frame — no placeholder flash, no reflow when paging back
        // to a page we've already shown.
        if let cached = ImageCache.shared.cachedImage(for: url) {
            _state = State(initialValue: .loaded(cached))
        } else if ImageCache.shared.isFailed(url) {
            _state = State(initialValue: .failed)
        } else {
            _state = State(initialValue: .loading)
        }
    }

    private enum LoadState {
        case loading
        case loaded(NSImage)
        case failed
    }

    /// How big to draw a picture, and how much of it to show.
    private struct Draw {
        /// Drawn width: never wider than the column, never wider than the
        /// picture's own pixels.
        var width: CGFloat
        /// Height the whole picture would occupy at that width.
        var full: CGFloat
        /// Height actually shown — `full`, capped.
        var shown: CGFloat
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                box(height: placeholderHeight) { skeleton }
            case .loaded(let img):
                let draw = draw(img)
                box(height: draw.shown) { picture(img, draw) }
            case .failed:
                // EmptyView collapses the slot entirely so the headline
                // below rises into the vacated space — no awkward whitespace.
                EmptyView()
            }
        }
        .task(id: url) { await load() }
    }

    /// A box as wide as the column offers and no wider, with its content laid
    /// over the top and clipped to it. `Color.clear` with a flexible width
    /// takes the proposed width without ever asking for more, which is what
    /// makes the width measurement below safe to feed back into the layout.
    private func box<Content: View>(
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { content() }
            .clipped()
            .background(widthProbe)
    }

    /// Zero-contribution probe that reports the box's width into `width`.
    private var widthProbe: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width, initial: true) { _, new in
                width = new
            }
        }
    }

    private func picture(_ img: NSImage, _ d: Draw) -> some View {
        Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fill)
            // Laid out at the FULL height, then slid up so the salient band
            // lands inside the box. The box clips the rest.
            .frame(width: d.width, height: d.full)
            .offset(y: -cropOffset(d))
    }

    /// Shown while the picture is DOWNLOADING, which is the only part of the
    /// pipeline that takes human-noticeable time — seconds on a slow host.
    /// A spinner rather than a static glyph, so a slow fetch reads as "working"
    /// instead of "broken".
    ///
    /// Deliberately NOT shown for the saliency pass: Vision costs 95ms on the
    /// process's first call (model load) and 8-16ms after that, measured on
    /// this edition's images, so a spinner there would flash for a single
    /// frame and read as a glitch.
    ///
    /// A picture that genuinely fails collapses to `EmptyView` instead — this
    /// skeleton never means "broken".
    private var skeleton: some View {
        Color.secondary.opacity(0.12)
            .overlay(ProgressView().controlSize(.small))
    }

    private func draw(_ img: NSImage) -> Draw {
        guard width > 0, img.size.width > 0, img.size.height > 0 else {
            // First layout pass, before the column has been measured. Reserve
            // the cap so the page doesn't lurch, and draw nothing yet.
            return Draw(width: 0, full: 0, shown: maxHeight ?? 0)
        }
        let pixels = CGFloat(img.representations.map(\.pixelsWide).max() ?? Int(img.size.width))
        let native = displayScale > 0 ? pixels / displayScale : img.size.width
        let w = min(width, native)
        let full = w * img.size.height / img.size.width
        return Draw(width: w, full: full, shown: min(full, maxHeight ?? full))
    }

    /// How far to slide the picture up so the crop window lands on the
    /// subject. 0 keeps a top-aligned crop, which is what we use when Vision
    /// found nothing salient.
    private func cropOffset(_ d: Draw) -> CGFloat {
        let slack = d.full - d.shown
        guard slack > 0, let y = salientY else { return 0 }
        // Vision's origin is bottom-left, so `1 - y` is the distance down from
        // the top of the picture.
        let centre = (1 - y) * d.full
        return min(max(centre - d.shown / 2, 0), slack)
    }

    /// Skeleton height: a 16:9 box once the width is known, held to the cap so
    /// the page doesn't lurch when the real picture arrives.
    private var placeholderHeight: CGFloat {
        let sixteenByNine = width > 0 ? width * 9 / 16 : nil
        return [sixteenByNine, maxHeight].compactMap { $0 }.min() ?? 0
    }

    private func load() async {
        // Synchronous hit — already decoded (covers an `init` that seeded
        // `.loaded`). The async `image(for:)` coalesces with any prefetch /
        // sibling view fetching the same URL, so the image is downloaded once.
        if let cached = ImageCache.shared.cachedImage(for: url) {
            state = .loaded(cached)
            await resolveSaliency(cached)
            return
        }
        if let img = await ImageCache.shared.image(for: url) {
            state = .loaded(img)
            await resolveSaliency(img)
        } else {
            state = .failed
            onFailure?()
        }
    }

    /// Ask Vision where the subject is. Only worth doing when there IS a cap —
    /// an uncapped picture is never cropped, so there is nothing to centre.
    private func resolveSaliency(_ img: NSImage) async {
        guard maxHeight != nil else { return }
        salientY = await SaliencyCache.shared.centreY(for: url, image: img)
    }
}
