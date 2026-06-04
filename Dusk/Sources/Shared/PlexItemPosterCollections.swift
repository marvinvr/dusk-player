import SwiftUI

struct ShowAllCarouselLink: View {
    let route: AppNavigationRoute
    var title = "Show all"

    var body: some View {
        NavigationLink(value: route) {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .showAllCarouselButtonStyle()
    }
}

private extension View {
    @ViewBuilder
    func showAllCarouselButtonStyle() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(.glass)
            .tint(Color.primary)
        #else
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .tint(Color.primary)
        } else {
            self
                .buttonStyle(.bordered)
                .tint(Color.primary)
        }
        #endif
    }
}

struct PlexItemPosterCarouselSection<ContextMenuContent: View>: View {
    let title: String
    let items: [PlexItem]
    var posterWidth: CGFloat = DuskPosterMetrics.carouselPosterWidth
    var showAllRoute: AppNavigationRoute? = nil
    var subtitle: (PlexItem) -> String?
    var posterURL: (PlexItem, Int, Int) -> URL?
    var progress: (PlexItem) -> Double? = { _ in nil }
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent

    var body: some View {
        let imageWidth = Int(posterWidth.rounded(.up))
        let imageHeight = Int((posterWidth * 1.5).rounded(.up))

        MediaCarousel(
            title: title,
            headerAccessory: {
                if let showAllRoute {
                    ShowAllCarouselLink(route: showAllRoute)
                }
            }
        ) {
            ForEach(items) { item in
                PosterNavigationCard(
                    route: AppNavigationRoute.destination(for: item),
                    imageURL: posterURL(item, imageWidth, imageHeight),
                    title: item.title,
                    subtitle: subtitle(item),
                    progress: progress(item),
                    width: posterWidth
                ) {
                    contextMenuContent(item)
                }
            }
        }
    }
}

extension PlexItemPosterCarouselSection where ContextMenuContent == EmptyView {
    init(
        title: String,
        items: [PlexItem],
        posterWidth: CGFloat = DuskPosterMetrics.carouselPosterWidth,
        showAllRoute: AppNavigationRoute? = nil,
        subtitle: @escaping (PlexItem) -> String?,
        posterURL: @escaping (PlexItem, Int, Int) -> URL?,
        progress: @escaping (PlexItem) -> Double? = { _ in nil }
    ) {
        self.title = title
        self.items = items
        self.posterWidth = posterWidth
        self.showAllRoute = showAllRoute
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.progress = progress
        self.contextMenuContent = { _ in EmptyView() }
    }
}

struct PlexItemActionCarouselSection<ContextMenuContent: View>: View {
    let title: String
    let items: [PlexItem]
    let action: (PlexItem) -> Void
    var posterWidth: CGFloat
    var imageAspectRatio: CGFloat
    var showAllRoute: AppNavigationRoute? = nil
    var subtitle: (PlexItem) -> String?
    var posterURL: (PlexItem, Int, Int) -> URL?
    var progress: (PlexItem) -> Double? = { _ in nil }
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent

    var body: some View {
        let imageWidth = Int(posterWidth.rounded(.up))
        let imageHeight = Int((posterWidth / imageAspectRatio).rounded(.up))

        MediaCarousel(
            title: title,
            headerAccessory: {
                if let showAllRoute {
                    ShowAllCarouselLink(route: showAllRoute)
                }
            }
        ) {
            ForEach(items) { item in
                PosterActionCard(
                    action: { action(item) },
                    imageURL: posterURL(item, imageWidth, imageHeight),
                    title: item.continueWatchingDisplayTitle,
                    subtitle: subtitle(item),
                    progress: progress(item),
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio,
                    showsPlayOverlay: true
                ) {
                    contextMenuContent(item)
                }
            }
        }
    }
}

struct PlexItemPosterGrid<ContextMenuContent: View>: View {
    let items: [PlexItem]
    let layout: AdaptivePosterGridLayout
    var rowSpacing: CGFloat = DuskPosterMetrics.detailGridRowSpacing
    var posterURL: (PlexItem, Int, Int) -> URL?
    var subtitle: (PlexItem) -> String?
    var progress: (PlexItem) -> Double? = { _ in nil }
    var onItemAppear: (PlexItem) -> Void = { _ in }
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent

    var body: some View {
        let imageWidth = Int(layout.posterWidth.rounded(.up))
        let imageHeight = Int((layout.posterWidth * 1.5).rounded(.up))

        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: rowSpacing) {
            ForEach(items) { item in
                PosterNavigationCard(
                    route: AppNavigationRoute.destination(for: item),
                    imageURL: posterURL(item, imageWidth, imageHeight),
                    title: item.title,
                    subtitle: subtitle(item),
                    progress: progress(item),
                    width: layout.posterWidth
                ) {
                    contextMenuContent(item)
                }
                .onAppear {
                    onItemAppear(item)
                }
            }
        }
    }
}

extension PlexItemPosterGrid where ContextMenuContent == EmptyView {
    init(
        items: [PlexItem],
        layout: AdaptivePosterGridLayout,
        rowSpacing: CGFloat = DuskPosterMetrics.detailGridRowSpacing,
        posterURL: @escaping (PlexItem, Int, Int) -> URL?,
        subtitle: @escaping (PlexItem) -> String?,
        progress: @escaping (PlexItem) -> Double? = { _ in nil },
        onItemAppear: @escaping (PlexItem) -> Void = { _ in }
    ) {
        self.items = items
        self.layout = layout
        self.rowSpacing = rowSpacing
        self.posterURL = posterURL
        self.subtitle = subtitle
        self.progress = progress
        self.onItemAppear = onItemAppear
        self.contextMenuContent = { _ in EmptyView() }
    }
}
