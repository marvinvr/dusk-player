import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SearchView: View {
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            SearchRootContent()
                .duskAppNavigationDestinations()
        }
    }
}

/// The search screen without its own `NavigationStack`, usable both as the
/// Search tab's root and as a destination pushed from the More tab.
struct SearchRootContent: View {
    @Environment(PlexService.self) private var plexService
    @State private var viewModel: SearchViewModel?

    private let searchPrompt = "Movies, Shows, Actors..."

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if let viewModel {
                searchContent(viewModel)
            }
        }
        .duskNavigationTitle("Search")
        .duskNavigationBarTitleDisplayModeLarge()
        .onAppear {
            if viewModel == nil {
                viewModel = SearchViewModel(plexService: plexService)
            }
        }
    }

    @ViewBuilder
    private func searchContent(_ vm: SearchViewModel) -> some View {
        platformResults(vm)
            .onChange(of: vm.query) {
                vm.searchDebounced()
            }
    }

    /// Picks the result layout that feels native to each platform:
    /// - tvOS and iPad (regular width) render the same poster carousels the Home
    ///   screen uses for hubs.
    /// - iPhone (compact width) renders a poster grid, matching the library grid
    ///   and how media apps present search on a narrow screen.
    @ViewBuilder
    private func platformResults(_ vm: SearchViewModel) -> some View {
        @Bindable var vm = vm

        #if os(tvOS)
        carouselResults(vm)
            .searchable(text: $vm.query, prompt: searchPrompt)
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            carouselResults(vm)
                .searchable(
                    text: $vm.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt
                )
        } else {
            gridResults(vm)
                .searchable(text: $vm.query, prompt: searchPrompt)
        }
        #endif
    }
}

// MARK: - Shared Results

private extension SearchRootContent {
    /// Wraps the populated results with the shared loading / error / empty states
    /// so every platform reports state the same way.
    @ViewBuilder
    func searchResults<Content: View>(
        _ vm: SearchViewModel,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if vm.isSearching && vm.results.isEmpty {
            FeatureLoadingView()
        } else if let error = vm.error, vm.results.isEmpty {
            FeatureErrorView(message: error) {
                vm.searchDebounced()
            }
        } else if vm.hasSearched && vm.results.isEmpty {
            FeatureEmptyStateView(
                systemImage: "film.stack",
                title: "No results found",
                message: "Try a different title, show, or actor."
            )
        } else if vm.results.isEmpty {
            FeatureEmptyStateView(
                systemImage: "magnifyingglass",
                title: "Search your Plex library",
                message: "Find movies, shows, episodes, and people."
            )
        } else {
            content()
        }
    }

    /// Poster carousels, one per Plex search hub. Used by tvOS and iPad. Plex
    /// `/hubs/search` caps each type at 10 items, so a group maps onto a single
    /// focusable carousel row.
    @ViewBuilder
    func carouselResults(_ vm: SearchViewModel) -> some View {
        searchResults(vm) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
                    ForEach(vm.results) { group in
                        let isVideoGroup = group.items.isAllClips

                        PlexItemPosterCarouselSection(
                            title: group.title,
                            items: group.items,
                            posterWidth: isVideoGroup
                                ? DuskPosterMetrics.videoCarouselWidth
                                : DuskPosterMetrics.carouselPosterWidth,
                            imageAspectRatio: isVideoGroup ? 16.0 / 9.0 : 2.0 / 3.0,
                            subtitle: { $0.standardPosterSubtitle },
                            posterURL: { item, width, height in
                                vm.imageURL(for: item.preferredPosterPath, width: width, height: height)
                            },
                            progress: { $0.posterProgress }
                        )
                    }
                }
                .padding(.top, DuskPosterMetrics.pageSectionSpacing)
                .padding(.bottom, DuskPosterMetrics.pageBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(tvOS)
                .focusSection()
                #endif
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - iPhone Grid Results

#if os(iOS)
private extension SearchRootContent {
    /// Poster grid, one titled section per search hub. Used on iPhone, where a
    /// grid reads more naturally than carousels on a narrow screen and matches
    /// the library grid.
    @ViewBuilder
    func gridResults(_ vm: SearchViewModel) -> some View {
        searchResults(vm) {
            GeometryReader { geometry in
                let layout = AdaptivePosterGridLayout.make(
                    containerWidth: geometry.size.width,
                    horizontalPadding: DuskPosterMetrics.gridHorizontalPadding,
                    gridSpacing: DuskPosterMetrics.gridSpacing,
                    preferredPosterWidth: DuskPosterMetrics.gridPreferredWidth,
                    minimumColumnCount: 3
                )
                // All-clip groups use the wider 16:9 video layout that matches
                // the video library grid (~2 columns on iPhone).
                let videoLayout = AdaptivePosterGridLayout.make(
                    containerWidth: geometry.size.width,
                    horizontalPadding: DuskPosterMetrics.gridHorizontalPadding,
                    gridSpacing: DuskPosterMetrics.gridSpacing,
                    preferredPosterWidth: DuskPosterMetrics.videoGridPreferredWidth,
                    minimumColumnCount: 2
                )

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(vm.results) { group in
                            let isVideoGroup = group.items.isAllClips

                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.title)
                                    .font(.title3.bold())
                                    .foregroundStyle(Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                PlexItemPosterGrid(
                                    items: group.items,
                                    layout: isVideoGroup ? videoLayout : layout,
                                    rowSpacing: DuskPosterMetrics.gridRowSpacing,
                                    imageAspectRatio: isVideoGroup ? 16.0 / 9.0 : 2.0 / 3.0,
                                    posterURL: { item, width, height in
                                        vm.imageURL(for: item.preferredPosterPath, width: width, height: height)
                                    },
                                    subtitle: { $0.standardPosterSubtitle },
                                    progress: { $0.posterProgress }
                                )
                            }
                            .padding(.horizontal, DuskPosterMetrics.gridHorizontalPadding)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
#endif
