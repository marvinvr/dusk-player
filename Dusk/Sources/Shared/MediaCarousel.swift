import SwiftUI

/// Reusable horizontal carousel with a section title.
struct MediaCarousel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Color.duskTextPrimary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    content()
                }
                .padding(.horizontal)
                .padding(.bottom, 2)
            }
        }
    }
}
