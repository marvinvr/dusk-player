import SwiftUI

struct PosterNavigationCard<ContextMenuContent: View>: View {
    let route: AppNavigationRoute
    let imageURL: URL?
    let title: String
    var subtitle: String?
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay = false
    @ViewBuilder let contextMenuContent: () -> ContextMenuContent
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let artworkShape = RoundedRectangle(
            cornerRadius: PosterArtwork.cornerRadius,
            style: .continuous
        )

        VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
            NavigationLink(value: route) {
                PosterArtwork(
                    imageURL: imageURL,
                    progress: progress,
                    width: width,
                    imageAspectRatio: imageAspectRatio,
                    showsPlayOverlay: showsPlayOverlay
                )
                .contentShape(.contextMenuPreview, artworkShape)
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .contextMenu {
                contextMenuContent()
            }

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width
            )
        }
        .frame(width: width, alignment: .topLeading)
        .zIndex(isFocused ? 1 : 0)
        #else
        NavigationLink(value: route) {
            PosterCard(
                imageURL: imageURL,
                title: title,
                subtitle: subtitle,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio,
                showsPlayOverlay: showsPlayOverlay
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .contextMenu {
            contextMenuContent()
        }
        #endif
    }
}

extension PosterNavigationCard where ContextMenuContent == EmptyView {
    init(
        route: AppNavigationRoute,
        imageURL: URL?,
        title: String,
        subtitle: String? = nil,
        progress: Double? = nil,
        width: CGFloat = 130,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        showsPlayOverlay: Bool = false
    ) {
        self.route = route
        self.imageURL = imageURL
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.width = width
        self.imageAspectRatio = imageAspectRatio
        self.showsPlayOverlay = showsPlayOverlay
        self.contextMenuContent = { EmptyView() }
    }
}

struct PosterActionCard<ContextMenuContent: View>: View {
    let action: () -> Void
    let imageURL: URL?
    let title: String
    var subtitle: String?
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay = false
    @ViewBuilder let contextMenuContent: () -> ContextMenuContent
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let artworkShape = RoundedRectangle(
            cornerRadius: PosterArtwork.cornerRadius,
            style: .continuous
        )

        VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
            Button(action: action) {
                PosterArtwork(
                    imageURL: imageURL,
                    progress: progress,
                    width: width,
                    imageAspectRatio: imageAspectRatio,
                    showsPlayOverlay: showsPlayOverlay
                )
                .contentShape(.contextMenuPreview, artworkShape)
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .contextMenu {
                contextMenuContent()
            }

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width
            )
        }
        .frame(width: width, alignment: .topLeading)
        .zIndex(isFocused ? 1 : 0)
        #else
        Button(action: action) {
            PosterCard(
                imageURL: imageURL,
                title: title,
                subtitle: subtitle,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio,
                showsPlayOverlay: showsPlayOverlay
            )
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .contextMenu {
            contextMenuContent()
        }
        #endif
    }
}

extension PosterActionCard where ContextMenuContent == EmptyView {
    init(
        action: @escaping () -> Void,
        imageURL: URL?,
        title: String,
        subtitle: String? = nil,
        progress: Double? = nil,
        width: CGFloat = 130,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        showsPlayOverlay: Bool = false
    ) {
        self.action = action
        self.imageURL = imageURL
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.width = width
        self.imageAspectRatio = imageAspectRatio
        self.showsPlayOverlay = showsPlayOverlay
        self.contextMenuContent = { EmptyView() }
    }
}
