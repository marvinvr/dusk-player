import SwiftUI

struct EpisodeDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var viewModel: EpisodeDetailViewModel

    init(ratingKey: String, plexService: PlexService) {
        _viewModel = State(initialValue: EpisodeDetailViewModel(
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
                        ExpandableSummaryText(text: summary)
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
                    }

                    if let roles = details.roles, !roles.isEmpty {
                        castSection(roles)
                            .padding(.top, 24)
                    }
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func heroSection(_ details: PlexMediaDetails, topInset: CGFloat, containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
        let heroBase = min(max(containerHeight * 0.72, 520), 760)
        let heroHeight = heroBase + topInset
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up))),
            posterURL: nil,
            title: details.title,
            topInset: topInset,
            containerWidth: containerWidth,
            heroBaseHeight: heroBase,
            supertitle: {
                if let showTitle = viewModel.showTitle {
                    showTitleLink(showTitle)
                }
            },
            subtitle: {
                VStack(alignment: .leading, spacing: 6) {
                    episodeMarkerRow()
                    metadataTagline(details)
                    heroMetadata(details)
                }
            },
            actions: {
                actionButtons(details)
            }
        )
    }

    @ViewBuilder
    private func episodeMarkerRow() -> some View {
        let seasonLabel = viewModel.seasonLabel
        let episodeLabel = viewModel.episodeLabel

        if seasonLabel != nil || episodeLabel != nil {
            HStack(spacing: 0) {
                if let seasonLabel {
                    seasonMetadataLink(seasonLabel)
                }

                if seasonLabel != nil, episodeLabel != nil {
                    metadataSeparator
                }

                if let episodeLabel {
                    metadataMarkerText(episodeLabel)
                }
            }
        }
    }

    @ViewBuilder
    private func showTitleLink(_ title: String) -> some View {
        if let showRatingKey = viewModel.showRatingKey {
            NavigationLink(value: AppNavigationRoute.media(type: .show, ratingKey: showRatingKey)) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.duskAccent)
            }
            .buttonStyle(.plain)
            .duskSuppressTVOSButtonChrome()
        } else {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.duskAccent)
        }
    }

    @ViewBuilder
    private func seasonMetadataLink(_ title: String) -> some View {
        if let seasonRatingKey = viewModel.seasonRatingKey {
            NavigationLink(value: AppNavigationRoute.media(type: .season, ratingKey: seasonRatingKey)) {
                metadataMarkerText(title)
            }
            .buttonStyle(.plain)
            .duskSuppressTVOSButtonChrome()
        } else {
            metadataMarkerText(title)
        }
    }

    private func metadataMarkerText(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.76))
    }

    private var metadataSeparator: some View {
        Text(" · ")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.76))
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            details.contentRating,
            viewModel.formattedDuration,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.76))
        }
    }

    @ViewBuilder
    private func heroMetadata(_ details: PlexMediaDetails) -> some View {
        if let originalDate = MediaTextFormatter.localizedAirDate(details.originallyAvailableAt) {
            Text(originalDate)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.76))
        }

        if let rating = details.rating {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text(String(format: "%.1f", rating))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.white)
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ details: PlexMediaDetails) -> some View {
        let layout = sizeClass == .regular
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 12))

        layout {
            Button {
                Task { await playback.play(ratingKey: details.ratingKey) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play Episode")
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

            Button {
                Task { await viewModel.toggleWatched() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isWatched ? "eye.slash" : "eye")
                    Text(viewModel.isWatched ? "Mark Unwatched" : "Mark Watched")
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: usesFullWidthActionButtons ? .infinity : nil)
                .padding(.vertical, 12)
                .padding(.horizontal, usesFullWidthActionButtons ? 0 : 18)
                .background(Color.duskSurface)
                .foregroundStyle(Color.duskTextPrimary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                )
            }
            .duskSuppressTVOSButtonChrome()
        }
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
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(roles.prefix(20).enumerated()), id: \.offset) { _, role in
                        ActorCreditCard(person: PlexPersonReference(role: role), plexService: plexService)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
