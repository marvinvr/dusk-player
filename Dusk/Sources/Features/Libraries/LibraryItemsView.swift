import SwiftUI

struct LibraryItemsView: View {
    @State private var viewModel: LibraryItemsViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.gridHorizontalPadding
    private let gridSpacing: CGFloat = DuskPosterMetrics.gridSpacing
    private let gridRowSpacing: CGFloat = DuskPosterMetrics.gridRowSpacing
    private let minimumColumnCount = 2
    private let controlCornerRadius: CGFloat = 18

    init(
        library: PlexLibrary,
        plexService: PlexService,
        collection: PlexLibraryCollection? = nil,
        initialGenre: LibraryGenreOption? = nil,
        preferLocalGenreFiltering: Bool = false
    ) {
        _viewModel = State(initialValue: LibraryItemsViewModel(
            library: library,
            plexService: plexService,
            collection: collection,
            initialGenre: initialGenre,
            preferLocalGenreFiltering: preferLocalGenreFiltering
        ))
    }

    /// Video libraries browse in 16:9 clip cards; movie/show grids keep the
    /// standard 2:3 posters.
    private var preferredPosterWidth: CGFloat {
        viewModel.isVideoLibrary ? DuskPosterMetrics.videoGridPreferredWidth : DuskPosterMetrics.gridPreferredWidth
    }

    private var gridImageAspectRatio: CGFloat {
        viewModel.isVideoLibrary ? 16.0 / 9.0 : 2.0 / 3.0
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.items.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.items.isEmpty, !viewModel.showsBrowseControls {
                FeatureErrorView(message: error) {
                    Task { await viewModel.loadItems() }
                }
            } else {
                libraryContent
            }
        }
        .duskNavigationTitle(viewModel.navigationTitle)
        .duskNavigationBarTitleDisplayModeLarge()
        .task {
            await viewModel.loadItems()
        }
    }

    private var libraryContent: some View {
        GeometryReader { geometry in
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: horizontalPadding,
                gridSpacing: gridSpacing,
                preferredPosterWidth: preferredPosterWidth,
                minimumColumnCount: minimumColumnCount
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.showsBrowseControls {
                        browseControls
                    }

                    if let error = viewModel.error, viewModel.items.isEmpty {
                        FeatureErrorView(message: error) {
                            Task { await viewModel.reloadItems() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 40)
                    } else if viewModel.items.isEmpty {
                        emptyView
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, 40)
                    } else {
                        posterGrid(layout)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 32)
                        .padding(.bottom, 32)
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .tint(Color.duskAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    private var browseControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if viewModel.availableGenres.count > 1 {
                    genreMenu
                }

                sortMenu

                if viewModel.isLoading && !viewModel.items.isEmpty {
                    ProgressView()
                        .tint(Color.duskAccent)
                        .padding(.leading, 6)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private var genreMenu: some View {
        Menu {
            Section("Genre") {
                ForEach(viewModel.availableGenres) { genre in
                    Button {
                        Task { await viewModel.selectGenre(genre) }
                    } label: {
                        if genre == viewModel.selectedGenre {
                            Label(genre.title, systemImage: "checkmark")
                        } else {
                            Text(genre.title)
                        }
                    }
                }
            }
        } label: {
            browseControlLabel(
                value: viewModel.selectedGenre.title,
                systemImage: "line.3.horizontal.decrease.circle",
                isActive: viewModel.selectedGenre != .all
            )
        }
        .duskSuppressTVOSButtonChrome()
    }

    private var sortMenu: some View {
        Menu {
            Section("Sort") {
                ForEach(viewModel.availableSortOptions) { sort in
                    Button {
                        Task { await viewModel.selectSort(sort) }
                    } label: {
                        if sort == viewModel.selectedSort {
                            Label(sort.title, systemImage: "checkmark")
                        } else {
                            Text(sort.title)
                        }
                    }
                }
            }
        } label: {
            browseControlLabel(
                value: viewModel.selectedSort.title,
                systemImage: "arrow.up.arrow.down.circle",
                isActive: viewModel.selectedSort != viewModel.defaultSortOption
            )
        }
        .duskSuppressTVOSButtonChrome()
    }

    private func browseControlLabel(
        value: String,
        systemImage: String,
        isActive: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(isActive ? Color.duskAccent : Color.duskTextSecondary)

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.duskTextSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                .fill(Color.duskSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                .stroke(
                    isActive ? Color.duskAccent.opacity(0.45) : Color.duskTextSecondary.opacity(0.18),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(systemImage == "line.3.horizontal.decrease.circle" ? "Genre" : "Sort")
        .accessibilityValue(value)
        .duskTVOSFocusEffectShape(RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous))
    }

    private func posterGrid(_ layout: AdaptivePosterGridLayout) -> some View {
        PlexItemPosterGrid(
            items: viewModel.items,
            layout: layout,
            rowSpacing: gridRowSpacing,
            imageAspectRatio: gridImageAspectRatio,
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            },
            subtitle: { viewModel.subtitle(for: $0) },
            progress: { viewModel.progress(for: $0) },
            onItemAppear: { item in
                Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
            }
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
    }

    private var emptyView: some View {
        FeatureEmptyStateView(
            systemImage: viewModel.isVideoLibrary ? "play.rectangle.fill" : "film",
            title: viewModel.emptyStateTitle,
            message: viewModel.emptyStateMessage
        )
    }
}
