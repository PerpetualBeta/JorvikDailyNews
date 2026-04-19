import SwiftUI

struct Masthead: View {
    let date: Date

    private var dateline: String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: date).uppercased()
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("Jorvik Daily News")
                .font(.custom("Didot", size: 64))
                .kerning(1)
                .fixedSize()
            Text("Nuntii ex orbe terrarum")
                .font(.custom("Didot", size: 15))
                .italic()
                .kerning(1.2)
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.bottom, 2)
            HStack(spacing: 12) {
                Rectangle().fill(Color.primary).frame(height: 1)
                Text(dateline)
                    .font(.custom("Charter", size: 11))
                    .kerning(2)
                    .fixedSize()
                Rectangle().fill(Color.primary).frame(height: 1)
            }
            .padding(.horizontal, 4)
        }
    }
}
