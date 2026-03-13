import SwiftUI

struct SeasonDetailView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var viewModel: SeasonDetailViewModel

    private let horizontalPadding: CGFloat = 20

    init(ratingKey: String, plexService: PlexService) {
        _viewModel = State(initialValue: SeasonDetailViewModel(
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
                    heroSection(details, topInset: geometry.safeAreaInsets.top, containerWidth: geometry.size.width)

                    if let summary = details.summary, !summary.isEmpty {
                        ExpandableSummaryText(text: summary)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 20)
                    }

                    episodesSection(width: geometry.size.width)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func heroSection(_ details: PlexMediaDetails, topInset: CGFloat, containerWidth: CGFloat) -> some View {
        let heroHeight = 340 + topInset
        let backdropWidth = Int(containerWidth.rounded(.up))
        let backdropHeight = Int(heroHeight.rounded(.up))

        ZStack(alignment: .bottomLeading) {
            DetailHeroBackdrop(
                imageURL: viewModel.backdropURL(width: backdropWidth, height: backdropHeight),
                height: heroHeight
            )

            LinearGradient(
                colors: [.clear, Color.duskBackground.opacity(0.6), Color.duskBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)

            HStack(alignment: .bottom, spacing: 16) {
                seasonArtwork

                VStack(alignment: .leading, spacing: 10) {
                    if let showTitle = viewModel.showTitle {
                        if let showRatingKey = viewModel.showRatingKey {
                            NavigationLink(value: AppNavigationRoute.media(type: .show, ratingKey: showRatingKey)) {
                                Text(showTitle)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.duskAccent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .duskSuppressTVOSButtonChrome()
                        } else {
                            Text(showTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.duskAccent)
                        }
                    }

                    Text(details.title)
                        .font(.title2.bold())
                        .foregroundStyle(Color.duskTextPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    metadataTagline(details)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 16)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            viewModel.episodeCountText,
            viewModel.watchedEpisodeCountText,
            details.contentRating,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    @ViewBuilder
    private func episodesSection(width: CGFloat) -> some View {
        if !viewModel.episodes.isEmpty {
            let contentWidth = max(width - (horizontalPadding * 2), 280)
            let artworkWidth = min(max(contentWidth * 0.48, 170), 320)
            let imageWidth = Int(artworkWidth.rounded(.up))
            let imageHeight = Int((artworkWidth / (16.0 / 9.0)).rounded(.up))

            VStack(alignment: .leading, spacing: 16) {
                Text("Episodes")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)

                LazyVStack(spacing: 20) {
                    ForEach(viewModel.episodes) { episode in
                        NavigationLink(value: AppNavigationRoute.media(type: .episode, ratingKey: episode.ratingKey)) {
                            SeasonEpisodeRow(
                                episode: episode,
                                imageURL: viewModel.episodeImageURL(episode, width: imageWidth, height: imageHeight),
                                label: viewModel.episodeLabel(episode),
                                subtitle: viewModel.episodeSubtitle(episode),
                                progress: viewModel.progress(for: episode),
                                artworkWidth: artworkWidth
                            )
                            .id(episode.ratingKey)
                            .contextMenu {
                                episodeContextMenu(episode)
                            }
                        }
                        .buttonStyle(.plain)
                        .duskSuppressTVOSButtonChrome()
                        .duskTVOSFocusEffectShape(Rectangle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func episodeContextMenu(_ episode: PlexEpisode) -> some View {
        if episode.isPartiallyWatched {
            Button {
                Task { await playback.playFromStart(ratingKey: episode.ratingKey) }
            } label: {
                Label("Play from Start", systemImage: "arrow.counterclockwise")
            }
        }

        Button {
            Task { await viewModel.toggleWatched(for: episode) }
        } label: {
            Label(
                episode.isWatched ? "Mark Unwatched" : "Mark Watched",
                systemImage: episode.isWatched ? "eye.slash" : "eye"
            )
        }
    }

    @ViewBuilder
    private var seasonArtwork: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        if let posterURL = viewModel.posterURL(width: 112, height: 168) {
            AsyncImage(url: posterURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                default:
                    shape.fill(Color.duskBackground)
                }
            }
            .frame(width: 112)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(shape)
        } else {
            shape
                .fill(Color.duskBackground)
                .frame(width: 112)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
        }
    }
}

private struct SeasonEpisodeRow: View {
    let episode: PlexEpisode
    let imageURL: URL?
    let label: String?
    let subtitle: String?
    let progress: Double?
    let artworkWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                artwork

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let label, !label.isEmpty {
                            Text(label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.duskTextSecondary)
                        }

                        if episode.isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.duskAccent)
                        }
                    }

                    Text(episode.title)
                        .font(.headline)
                        .foregroundStyle(Color.duskTextPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if let summary = episode.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
                    .lineSpacing(4)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    default:
                        Color.duskBackground
                            .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    }
                }
            } else {
                Color.duskBackground
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
            }

            Image(systemName: "play.fill")
                .font(.system(size: artworkWidth * 0.16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(artworkWidth * 0.09)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if let progress {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.2))
                                .frame(height: 3)

                            Rectangle()
                                .fill(Color.duskAccent)
                                .frame(width: geometry.size.width * progress, height: 3)
                        }
                    }
                }
            }
        }
        .frame(width: artworkWidth)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
