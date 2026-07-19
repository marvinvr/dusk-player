import SwiftUI

/// Reusable horizontal carousel with a section title.
struct MediaCarousel<Content: View, HeaderAccessory: View>: View {
    let title: String
    let horizontalPadding: CGFloat
    let headerAccessory: HeaderAccessory
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding,
        @ViewBuilder content: @escaping () -> Content
    ) where HeaderAccessory == EmptyView {
        self.title = title
        self.horizontalPadding = horizontalPadding
        self.headerAccessory = EmptyView()
        self.content = content
    }

    init(
        title: String,
        horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.horizontalPadding = horizontalPadding
        self.headerAccessory = headerAccessory()
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.carouselSectionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: DuskPosterMetrics.carouselHeaderSpacing) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 0)

                headerAccessory
            }
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
