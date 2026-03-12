import SwiftUI

struct LibraryItemsView: View {
    @State private var viewModel: LibraryItemsViewModel

    private let horizontalPadding: CGFloat = 12
    private let gridSpacing: CGFloat = 12
    private let gridRowSpacing: CGFloat = 18
    private let preferredPosterWidth: CGFloat = 104
    private let minimumColumnCount = 2

    init(library: PlexLibrary, plexService: PlexService) {
        _viewModel = State(initialValue: LibraryItemsViewModel(
            library: library,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView()
                    .tint(Color.duskAccent)
            } else if let error = viewModel.error, viewModel.items.isEmpty {
                errorView(error)
            } else if viewModel.items.isEmpty {
                emptyView
            } else {
                itemsGrid
            }
        }
        .duskNavigationTitle(viewModel.library.title)
        .duskNavigationBarTitleDisplayModeLarge()
        .task {
            await viewModel.loadItems()
        }
    }

    // MARK: - Grid

    private var itemsGrid: some View {
        GeometryReader { geometry in
            let layout = gridLayout(for: geometry.size.width)
            let imageWidth = Int(layout.posterWidth.rounded(.up))
            let imageHeight = Int((layout.posterWidth * 1.5).rounded(.up))

            ScrollView {
                LazyVGrid(columns: layout.columns, spacing: gridRowSpacing) {
                    ForEach(viewModel.items) { item in
                        #if os(tvOS)
                        VStack(alignment: .leading, spacing: 6) {
                            NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                                PosterArtwork(
                                    imageURL: viewModel.posterURL(for: item, width: imageWidth, height: imageHeight),
                                    progress: viewModel.progress(for: item),
                                    width: layout.posterWidth
                                )
                            }
                            .buttonStyle(.plain)
                            .duskSuppressTVOSButtonChrome()

                            PosterCardText(
                                title: item.title,
                                subtitle: viewModel.subtitle(for: item),
                                width: layout.posterWidth
                            )
                        }
                        .frame(width: layout.posterWidth, alignment: .topLeading)
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
                        }
                        #else
                        NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                            PosterCard(
                                imageURL: viewModel.posterURL(for: item, width: imageWidth, height: imageHeight),
                                title: item.title,
                                subtitle: viewModel.subtitle(for: item),
                                progress: viewModel.progress(for: item),
                                width: layout.posterWidth
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .duskSuppressTVOSButtonChrome()
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
                        }
                        #endif
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 8)

                if viewModel.isLoadingMore {
                    ProgressView()
                        .tint(Color.duskAccent)
                        .padding(.vertical, 20)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func gridLayout(for containerWidth: CGFloat) -> (columns: [GridItem], posterWidth: CGFloat) {
        let availableWidth = max(containerWidth - (horizontalPadding * 2), preferredPosterWidth)
        let rawColumnCount = Int((availableWidth + gridSpacing) / (preferredPosterWidth + gridSpacing))
        let columnCount = max(rawColumnCount, minimumColumnCount)
        let totalSpacing = CGFloat(columnCount - 1) * gridSpacing
        let posterWidth = floor((availableWidth - totalSpacing) / CGFloat(columnCount))
        let columns = Array(
            repeating: GridItem(.fixed(posterWidth), spacing: gridSpacing, alignment: .top),
            count: columnCount
        )

        return (columns, posterWidth)
    }

    // MARK: - Empty / Error

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.largeTitle)
                .foregroundStyle(Color.duskTextSecondary)
            Text("This library is empty")
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.duskTextSecondary)
            Text(message)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task { await viewModel.loadItems() }
            }
            .foregroundStyle(Color.duskAccent)
            .duskSuppressTVOSButtonChrome()
        }
    }
}
