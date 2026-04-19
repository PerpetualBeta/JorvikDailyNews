import SwiftUI
import AppKit

/// Image view that fetches via URLSession and COLLAPSES on failure —
/// unlike AsyncImage which keeps its frame even when the load fails or the
/// URL resolves to a tiny/blank tracking pixel. On success it renders at
/// the specified height, aspect-fill, clipped.
struct OptionalImage: View {
    let url: URL
    let height: CGFloat

    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(NSImage)
        case failed
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                Color.secondary.opacity(0.08)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            case .loaded(let img):
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
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
