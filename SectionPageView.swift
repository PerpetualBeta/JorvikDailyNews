import SwiftUI
import AppKit

struct SectionPageView: View {
    let page: SectionPage
    let date: Date
    let pageNumber: Int
    let totalPages: Int

    private var dateline: String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: date).uppercased()
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                HStack {
                    Text(dateline)
                        .font(.custom("Charter", size: 10))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Page \(pageNumber) of \(totalPages)")
                        .font(.custom("Charter", size: 10))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
                Text(page.name)
                    .font(.custom("Didot", size: 56))
                    .kerning(2)
            }
            Rectangle().fill(Color.primary).frame(height: 3)

            MasonryColumns(
                items: page.items,
                columns: 3,
                spacing: 28,
                estimateHeight: StoryCard.estimateHeight
            ) { item in
                StoryCard(item: item)
            }
        }
    }
}
