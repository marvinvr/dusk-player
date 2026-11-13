import SwiftUI

/// The paged poster grid of a movie or TV library's collections, reached from
/// the library grid's Collections chip and the Recommended page's Collections
/// row. Each poster opens `CollectionDetailView`.
struct LibraryCollectionsView: View {
    @State private var viewModel: LibraryCollectionsViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.gridHorizontalPadding
    private let gridSpacing: CGFloat = DuskPosterMetrics.gridSpacing
    private let gridRowSpacing: CGFloat = DuskPosterMetrics.gridRowSpacing

    init(library: PlexLibrary, plexService: PlexService) {
        _viewModel = State(initialValue: LibraryCollectionsViewModel(
            library: library,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if !viewModel.pager.hasLoadedOnce && viewModel.items.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.pager.error, viewModel.items.isEmpty {
                FeatureErrorView(message: error) {
                    Task { await viewModel.reload() }
                }
            } else if viewModel.items.isEmpty {
                FeatureEmptyStateView(
                    systemImage: "square.stack",
                    title: "No collections",
                    message: "Collections made in Plex for \(viewModel.library.title) show up here."
                )
                .padding(.horizontal, 24)
            } else {
                grid
            }
        }
        #if os(macOS)
        .macUILibraryPageTitle(viewModel.navigationTitle)
        #else
        .duskNavigationTitle(viewModel.navigationTitle)
        #endif
        .duskNavigationBarTitleDisplayModeLarge()
        .task {
            await viewModel.load()
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: horizontalPadding,
                gridSpacing: gridSpacing,
                preferredPosterWidth: DuskPosterMetrics.gridPreferredWidth,
                minimumColumnCount: 2
            )

            ScrollView {
                VStack(spacing: 0) {
                    PlexItemPosterGrid(
                        items: viewModel.items,
                        layout: layout,
                        rowSpacing: gridRowSpacing,
                        posterURL: { item, width, height in
                            viewModel.posterURL(for: item, width: width, height: height)
                        },
                        subtitle: { viewModel.subtitle(for: $0) },
                        onItemAppear: { item in
                            Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
                        }
                    )
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 16)
                    .padding(.bottom, 32)

                    if viewModel.pager.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .refreshable {
                await viewModel.reload()
            }
        }
    }
}
