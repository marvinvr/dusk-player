import SwiftUI

struct ActorDetailView: View {
    @State private var viewModel: ActorDetailViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding
    private let gridSpacing: CGFloat = {
        #if os(tvOS)
        DuskPosterMetrics.gridSpacing
        #else
        DuskPosterMetrics.detailGridSpacing
        #endif
    }()
    private let preferredPosterWidth: CGFloat = {
        #if os(tvOS)
        DuskPosterMetrics.gridPreferredWidth
        #else
        DuskPosterMetrics.detailGridPreferredWidth
        #endif
    }()
    private let minimumColumnCount = 2

    init(person: PlexPersonReference, plexService: PlexService) {
        _viewModel = State(initialValue: ActorDetailViewModel(
            person: person,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.filmography.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.filmography.isEmpty {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else {
                contentView
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.load()
        }
    }

    private var contentView: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerCard
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 36)

                    if !viewModel.movies.isEmpty {
                        filmographySection(
                            title: "Movies",
                            items: viewModel.movies,
                            width: geometry.size.width
                        )
                    }

                    if !viewModel.shows.isEmpty {
                        filmographySection(
                            title: "Shows",
                            items: viewModel.shows,
                            width: geometry.size.width
                        )
                    }

                    if viewModel.movies.isEmpty && viewModel.shows.isEmpty && !viewModel.isLoading {
                        emptyState
                            .padding(.horizontal, horizontalPadding)
                    }
                }
                .padding(.bottom, 56)
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    private var headerCard: some View {
        let artworkSize: CGFloat = {
            #if os(tvOS)
            160
            #else
            120
            #endif
        }()
        let headerSpacing: CGFloat = {
            #if os(tvOS)
            40
            #else
            20
            #endif
        }()

        return HStack(alignment: .center, spacing: headerSpacing) {
            personArtwork(size: artworkSize)

            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.person.name)
                    .font(.title2.bold())
                    .foregroundStyle(Color.duskTextPrimary)
                    .multilineTextAlignment(.leading)

                if let roleName = viewModel.person.roleName, !roleName.isEmpty {
                    Text(roleName)
                        .font(.subheadline)
                        .foregroundStyle(Color.duskTextSecondary)
                }

                Text(viewModel.creditSummary)
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private func personArtwork(size: CGFloat) -> some View {
        let imageSize = Int(size.rounded())
        let artworkShape = RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)

        if let imageURL = viewModel.personImageURL(size: imageSize) {
            DuskAsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    personPlaceholder(size: size)
                }
            }
            .frame(width: size, height: size)
            #if os(tvOS)
            .clipShape(artworkShape)
            #else
            .clipShape(Circle())
            #endif
        } else {
            personPlaceholder(size: size)
                .frame(width: size, height: size)
                #if os(tvOS)
                .clipShape(artworkShape)
                #else
                .clipShape(Circle())
                #endif
        }
    }

    private func personPlaceholder(size: CGFloat) -> some View {
        ZStack {
            #if os(tvOS)
            RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)
                .fill(Color.duskBackground)
            #else
            Circle()
                .fill(Color.duskBackground)
            #endif

            Image(systemName: "person.fill")
                .font(.system(size: size * 0.30, weight: .regular))
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    @ViewBuilder
    private func filmographySection(title: String, items: [PlexItem], width: CGFloat) -> some View {
        let layout = AdaptivePosterGridLayout.make(
            containerWidth: width,
            horizontalPadding: horizontalPadding,
            gridSpacing: gridSpacing,
            preferredPosterWidth: preferredPosterWidth,
            minimumColumnCount: minimumColumnCount
        )
        let imageWidth = Int(layout.posterWidth.rounded(.up))
        let imageHeight = Int((layout.posterWidth * 1.5).rounded(.up))
        let sectionSpacing: CGFloat = {
            #if os(tvOS)
            30
            #else
            16
            #endif
        }()

        VStack(alignment: .leading, spacing: sectionSpacing) {
            Text(title)
                .font(sectionTitleFont)
                .foregroundStyle(Color.duskTextPrimary)
                .padding(.horizontal, horizontalPadding)

            LazyVGrid(columns: layout.columns, alignment: .leading, spacing: DuskPosterMetrics.detailGridRowSpacing) {
                ForEach(items) { item in
                    PosterNavigationCard(
                        route: AppNavigationRoute.destination(for: item),
                        imageURL: viewModel.posterURL(for: item, width: imageWidth, height: imageHeight),
                        title: item.title,
                        subtitle: viewModel.subtitle(for: item),
                        width: layout.posterWidth
                    )
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
    }

    private var sectionTitleFont: Font {
        #if os(tvOS)
        .title3.bold()
        #else
        .headline
        #endif
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No titles found")
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)

            Text("This actor doesn't have any movies or shows available in your connected Plex library.")
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
