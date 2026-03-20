import SwiftUI

struct HomeHubItemsView: View {
    @State private var viewModel: HomeHubItemsViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.gridHorizontalPadding
    private let gridSpacing: CGFloat = DuskPosterMetrics.gridSpacing
    private let gridRowSpacing: CGFloat = DuskPosterMetrics.gridRowSpacing
    private let preferredPosterWidth: CGFloat = DuskPosterMetrics.gridPreferredWidth
    private let minimumColumnCount = 2

    init(hub: PlexHub, plexService: PlexService) {
        _viewModel = State(initialValue: HomeHubItemsViewModel(
            hub: hub,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.items.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.items.isEmpty {
                FeatureErrorView(message: error) {
                    Task { await viewModel.reloadItems() }
                }
            } else if viewModel.items.isEmpty {
                emptyView
            } else {
                itemsGrid
            }
        }
        .duskNavigationTitle(viewModel.navigationTitle)
        .duskNavigationBarTitleDisplayModeLarge()
        .task {
            await viewModel.loadItems()
        }
    }

    private var itemsGrid: some View {
        GeometryReader { geometry in
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: horizontalPadding,
                gridSpacing: gridSpacing,
                preferredPosterWidth: preferredPosterWidth,
                minimumColumnCount: minimumColumnCount
            )
            let imageWidth = Int(layout.posterWidth.rounded(.up))
            let imageHeight = Int((layout.posterWidth * 1.5).rounded(.up))

            ScrollView {
                LazyVGrid(columns: layout.columns, spacing: gridRowSpacing) {
                    ForEach(viewModel.items) { item in
                        PosterNavigationCard(
                            route: AppNavigationRoute.destination(for: item),
                            imageURL: viewModel.posterURL(for: item, width: imageWidth, height: imageHeight),
                            title: item.title,
                            subtitle: viewModel.subtitle(for: item),
                            progress: viewModel.progress(for: item),
                            width: layout.posterWidth
                        ) {
                            PlexItemContextMenuContent(
                                item: item,
                                onMarkWatched: {
                                    Task { await viewModel.setWatched(true, for: item) }
                                },
                                onMarkUnwatched: {
                                    Task { await viewModel.setWatched(false, for: item) }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 32)
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    private var emptyView: some View {
        FeatureEmptyStateView(systemImage: "film", title: "No items found")
    }
}
