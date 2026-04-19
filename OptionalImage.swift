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

    @State private var state: LoadState = .loading

    init(url: URL, height: CGFloat? = nil) {
        self.url = url
        self.height = height
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
                if let h = height {
                    Color.secondary.opacity(0.08)
                        .frame(maxWidth: .infinity)
                        .frame(height: h)
                } else {
                    Color.secondary.opacity(0.08)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
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

    private func load() async {
        state = .loading
        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            state = .failed
            return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            state = .failed
            return
        }
        guard let img = NSImage(data: data) else {
            state = .failed
            return
        }
        // Filter out 1×1 trackers and icon-sized placeholders some feeds
        // point to when they have no real hero image.
        let size = img.size
        if size.width < 48 || size.height < 48 {
            state = .failed
            return
        }
        state = .loaded(img)
    }
}
