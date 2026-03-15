import SwiftUI

struct ShowDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var viewModel: ShowDetailViewModel

    private let horizontalPadding: CGFloat = 20
    private let gridSpacing: CGFloat = 14
    private let preferredPosterWidth: CGFloat = 120
    private let minimumColumnCount = 2

    init(ratingKey: String, plexService: PlexService) {
        _viewModel = State(initialValue: ShowDetailViewModel(
            ratingKey: ratingKey,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.details == nil {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.details == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else if let details = viewModel.details {
                contentView(details)
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private func contentView(_ details: PlexMediaDetails) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(details, topInset: geometry.safeAreaInsets.top, containerWidth: geometry.size.width, containerHeight: geometry.size.height)

                    if let summary = details.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineSpacing(4)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 16)
                    }

                    seasonsSection(width: geometry.size.width)
                        .padding(.top, 24)

                    if let roles = details.roles, !roles.isEmpty {
                        castSection(roles)
                            .padding(.top, 24)
                            .padding(.bottom, 40)
                    }
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func heroSection(_ details: PlexMediaDetails, topInset: CGFloat, containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
        let heroBase = min(max(containerHeight * 0.72, 520), 760)
        let heroHeight = heroBase + topInset
        let posterWidth = sizeClass == .regular ? 180 : 120
        let posterHeight = Int((Double(posterWidth) * 1.5).rounded())
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up))),
            posterURL: viewModel.posterURL(width: posterWidth, height: posterHeight),
            title: details.title,
            topInset: topInset,
            containerWidth: containerWidth,
            heroBaseHeight: heroBase,
            posterWidth: CGFloat(posterWidth)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                metadataTagline(details)
                heroMetadata(details)
            }
        } actions: {
            if viewModel.nextEpisode != nil {
                actionButtons()
            }
        }
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            details.year.map(String.init),
            details.contentRating,
            viewModel.seasonCountText,
            viewModel.episodeCountText,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.76))
        }
    }

    @ViewBuilder
    private func heroMetadata(_ details: PlexMediaDetails) -> some View {
        if let genres = viewModel.genreText {
            Text(genres)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.76))
        }

        if let rating = details.rating {
            HStack(spacing: 12) {
                ratingBadge(
                    icon: "star.fill",
                    value: String(format: "%.1f", rating),
                    color: .yellow
                )

                if let audience = details.audienceRating {
                    ratingBadge(
                        icon: "person.fill",
                        value: String(format: "%.0f%%", audience * 10),
                        color: Color.duskAccent
                    )
                }
            }
        }

        if let studio = details.studio {
            Text(studio)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.76))
        }
    }

    private func ratingBadge(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)

            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.white)
        }
    }

    @ViewBuilder
    private func actionButtons() -> some View {
        Button {
            if let ep = viewModel.nextEpisode {
                Task { await playback.play(ratingKey: ep.ratingKey) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(viewModel.playButtonLabel)
            }
            .font(.headline)
            .frame(maxWidth: usesFullWidthActionButtons ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, usesFullWidthActionButtons ? 0 : 18)
            .background(Color.duskAccent)
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
        .duskSuppressTVOSButtonChrome()
    }

    private var usesFullWidthActionButtons: Bool {
        sizeClass == .compact
    }

    @ViewBuilder
    private func castSection(_ roles: [PlexRole]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(roles.prefix(20).enumerated()), id: \.offset) { _, role in
                        ActorCreditCard(person: PlexPersonReference(role: role), plexService: plexService)
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
        }
    }

    @ViewBuilder
    private func seasonsSection(width: CGFloat) -> some View {
        if !viewModel.seasons.isEmpty {
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: width,
                horizontalPadding: horizontalPadding,
                gridSpacing: gridSpacing,
                preferredPosterWidth: preferredPosterWidth,
                minimumColumnCount: minimumColumnCount
            )
            let imageWidth = Int(layout.posterWidth.rounded(.up))
            let imageHeight = Int((layout.posterWidth * 1.5).rounded(.up))

            VStack(alignment: .leading, spacing: 16) {
                Text("Seasons")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)
                    .padding(.horizontal, horizontalPadding)

                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: 18) {
                    ForEach(viewModel.seasons) { season in
                        #if os(tvOS)
                        VStack(alignment: .leading, spacing: 6) {
                            NavigationLink(value: AppNavigationRoute.media(type: .season, ratingKey: season.ratingKey)) {
                                PosterArtwork(
                                    imageURL: viewModel.seasonPosterURL(season, width: imageWidth, height: imageHeight),
                                    progress: viewModel.seasonProgress(season),
                                    width: layout.posterWidth
                                )
                            }
                            .buttonStyle(.plain)
                            .duskSuppressTVOSButtonChrome()

                            PosterCardText(
                                title: season.title,
                                subtitle: viewModel.seasonSubtitle(season),
                                width: layout.posterWidth
                            )
                        }
                        .frame(width: layout.posterWidth, alignment: .topLeading)
                        .contextMenu {
                            seasonContextMenu(season)
                        }
                        #else
                        NavigationLink(value: AppNavigationRoute.media(type: .season, ratingKey: season.ratingKey)) {
                            PosterCard(
                                imageURL: viewModel.seasonPosterURL(season, width: imageWidth, height: imageHeight),
                                title: season.title,
                                subtitle: viewModel.seasonSubtitle(season),
                                progress: viewModel.seasonProgress(season),
                                width: layout.posterWidth
                            )
                        }
                        .buttonStyle(.plain)
                        .duskSuppressTVOSButtonChrome()
                        .contextMenu {
                            seasonContextMenu(season)
                        }
                        #endif
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
        }
    }

    @ViewBuilder
    private func seasonContextMenu(_ season: PlexSeason) -> some View {
        if season.isPartiallyWatched {
            Button {
                Task { await viewModel.markSeason(season, watched: true) }
            } label: {
                Label("Mark Watched", systemImage: "eye")
            }

            Button {
                Task { await viewModel.markSeason(season, watched: false) }
            } label: {
                Label("Mark Unwatched", systemImage: "eye.slash")
            }
        } else if season.isFullyWatched {
            Button {
                Task { await viewModel.markSeason(season, watched: false) }
            } label: {
                Label("Mark Unwatched", systemImage: "eye.slash")
            }
        } else {
            Button {
                Task { await viewModel.markSeason(season, watched: true) }
            } label: {
                Label("Mark Watched", systemImage: "eye")
            }
        }
    }
}
