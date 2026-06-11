import SwiftUI
import AppKit

/// Image view that fetches via URLSession and COLLAPSES on failure —
/// unlike AsyncImage which keeps its frame even when the load fails or the
/// URL resolves to a tiny/blank tracking pixel.
///
/// Two rendering modes:
/// - `height: 280` (etc.) — cropped to a fixed height, aspect-fill,
///   top-aligned so faces stay above the fold. Used on the front page
///   where lead and secondaries need predictable slot sizes.
/// - `height: nil` — natural aspect ratio, no cropping. Used in the
///   masonry section pages where columns flow independently.
struct OptionalImage: View {
    let url: URL
    let height: CGFloat?
    /// Called when the image fails to load (bad URL, non-2xx, undecodable, or
    /// tracker-sized). The lead uses this to demote itself when its image
    /// can't be shown; ordinary cards leave it nil and just collapse.
    let onFailure: (() -> Void)?

    @State private var state: LoadState

    init(url: URL, height: CGFloat? = nil, onFailure: (() -> Void)? = nil) {
        self.url = url
        self.height = height
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

    var body: some View {
        Group {
            switch state {
            case .loading:
                loadingPlaceholder
            case .loaded(let img):
                if let h = height {
                    // Fixed height: top-align the crop so faces stay in frame.
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: h, alignment: .top)
                        .clipped()
                } else {
                    // Natural aspect: fill card width, height follows the
                    // image's own ratio. No cropping, no beheadings.
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
            case .failed:
                // EmptyView collapses the slot entirely so the headline
                // below rises into the vacated space — no awkward whitespace.
                EmptyView()
            }
        }
        .task(id: url) { await load() }
    }

    /// A clearly-visible skeleton with a photo glyph, so a slow load reads as
    /// "image loading" rather than an empty/broken hero.
    @ViewBuilder
    private var loadingPlaceholder: some View {
        let fill = Color.secondary.opacity(0.12)
        let glyph = Image(systemName: "photo")
            .font(.system(size: 22))
            .foregroundStyle(Color.secondary.opacity(0.45))
        if let h = height {
            fill.frame(maxWidth: .infinity).frame(height: h).overlay(glyph)
        } else {
            fill.aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(glyph)
        }
    }

    private func load() async {
        // Synchronous hit — already decoded (covers an `init` that seeded
        // `.loaded`). The async `image(for:)` coalesces with any prefetch /
        // sibling view fetching the same URL, so the image is downloaded once.
        if let cached = ImageCache.shared.cachedImage(for: url) {
            state = .loaded(cached)
            return
        }
        if let img = await ImageCache.shared.image(for: url) {
            state = .loaded(img)
        } else {
            state = .failed
            onFailure?()
        }
    }
}
