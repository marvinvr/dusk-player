import SwiftUI

/// Reusable horizontal carousel with a section title.
struct MediaCarousel<Content: View>: View {
    let title: String
    let horizontalPadding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.horizontalPadding = horizontalPadding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.carouselSectionSpacing) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: DuskPosterMetrics.carouselItemSpacing) {
                    content()
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, DuskPosterMetrics.carouselBottomPadding)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }
}
