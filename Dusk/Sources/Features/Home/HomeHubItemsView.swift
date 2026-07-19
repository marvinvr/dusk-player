import SwiftUI

struct HomeHubItemsView: View {
    @State private var viewModel: HomeHubItemsViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.gridHorizontalPadding
    private let gridSpacing: CGFloat = DuskPosterMetrics.gridSpacing
    private let gridRowSpacing: CGFloat = DuskPosterMetrics.gridRowSpacing
    private let minimumColumnCount = 2

    private var isVideoHub: Bool {
        viewModel.items.isAllClips
    }

    private var preferredPosterWidth: CGFloat {
        isVideoHub ? DuskPosterMetrics.videoGridPreferredWidth : DuskPosterMetrics.gridPreferredWidth
    }

    private var imageAspectRatio: CGFloat {
        isVideoHub ? 16.0 / 9.0 : 2.0 / 3.0
    }

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
            ScrollView {
                PlexItemPosterGrid(
                    items: viewModel.items,
                    layout: layout,
                    rowSpacing: gridRowSpacing,
                    imageAspectRatio: imageAspectRatio,
                    posterURL: { item, width, height in
                        viewModel.posterURL(for: item, width: width, height: height)
                    },
                    subtitle: { viewModel.subtitle(for: $0) },
                    progress: { viewModel.progress(for: $0) }
                ) { item in
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
