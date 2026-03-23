import SwiftUI

struct LibraryItemsView: View {
    @State private var viewModel: LibraryItemsViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.gridHorizontalPadding
    private let gridSpacing: CGFloat = DuskPosterMetrics.gridSpacing
    private let gridRowSpacing: CGFloat = DuskPosterMetrics.gridRowSpacing
    private let preferredPosterWidth: CGFloat = DuskPosterMetrics.gridPreferredWidth
    private let minimumColumnCount = 2
    private let controlCornerRadius: CGFloat = 18

    init(
        library: PlexLibrary,
        plexService: PlexService,
        initialGenre: LibraryGenreOption? = nil,
        preferLocalGenreFiltering: Bool = false
    ) {
        _viewModel = State(initialValue: LibraryItemsViewModel(
            library: library,
            plexService: plexService,
            initialGenre: initialGenre,
            preferLocalGenreFiltering: preferLocalGenreFiltering
        ))
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
            let imageWidth = Int(layout.posterWidth.rounded(.up))
            let imageHeight = Int((layout.posterWidth * 1.5).rounded(.up))

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
                        LazyVGrid(columns: layout.columns, spacing: gridRowSpacing) {
                            ForEach(viewModel.items) { item in
                                gridItem(
                                    item,
                                    posterWidth: layout.posterWidth,
                                    imageWidth: imageWidth,
                                    imageHeight: imageHeight
                                )
                            }
                        }
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
                ForEach(LibrarySortOption.allCases) { sort in
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
                isActive: viewModel.selectedSort != .titleAscending
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

    @ViewBuilder
    private func gridItem(
        _ item: PlexItem,
        posterWidth: CGFloat,
        imageWidth: Int,
        imageHeight: Int
    ) -> some View {
        PosterNavigationCard(
            route: AppNavigationRoute.destination(for: item),
            imageURL: viewModel.posterURL(for: item, width: imageWidth, height: imageHeight),
            title: item.title,
            subtitle: viewModel.subtitle(for: item),
            progress: viewModel.progress(for: item),
            width: posterWidth
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
        .onAppear {
            Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
        }
    }

    private var emptyView: some View {
        FeatureEmptyStateView(
            systemImage: "film",
            title: viewModel.emptyStateTitle,
            message: viewModel.emptyStateMessage
        )
    }
}
