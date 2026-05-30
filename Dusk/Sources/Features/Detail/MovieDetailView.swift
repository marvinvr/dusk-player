import SwiftUI

struct MovieDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: MovieDetailViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        _viewModel = State(initialValue: MovieDetailViewModel(
            ratingKey: ratingKey,
            plexService: plexService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.details == nil {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.details == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.loadDetails() }
                }
            } else if let details = viewModel.details {
                contentView(details)
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.loadDetails()
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.refreshDetails() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.details != nil else { return }
            Task { await viewModel.refreshDetails() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(_ details: PlexMediaDetails) -> some View {
        GeometryReader { geometry in
            let heroBackgroundWidth: CGFloat = {
                #if os(tvOS)
                geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
                #else
                geometry.size.width
                #endif
            }()
            let heroBackgroundLeadingInset: CGFloat = {
                #if os(tvOS)
                geometry.safeAreaInsets.leading
                #else
                0
                #endif
            }()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(
                        details,
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: heroBackgroundWidth,
                        containerHeight: geometry.size.height,
                        backgroundLeadingInset: heroBackgroundLeadingInset
                    )
#if os(tvOS)
                    .focusSection()
#endif
                    if let summary = details.summary, !summary.isEmpty {
                        summarySection(summary)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 40)
                    }
                    if let offlineBannerText = viewModel.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 24)
                    }
                    if let roles = details.roles, !roles.isEmpty {
                        DetailCastSection(roles: roles, plexService: plexService)
                            .padding(.top, 40)
                    }
                    mediaInfoSection()
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 40)
                        .padding(.bottom, 56)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .duskTVOSPageBackground()
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(
        _ details: PlexMediaDetails,
        topInset: CGFloat,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        backgroundLeadingInset: CGFloat = 0
    ) -> some View {
        let heroBase = min(max(containerHeight * 0.72, 520), 760)
        let heroHeight = heroBase + topInset
        let posterWidth: CGFloat = {
            #if os(tvOS)
            DuskPosterMetrics.heroPosterWidth
            #else
            sizeClass == .regular ? 180 : 120
            #endif
        }()
        let posterImageWidth = Int(posterWidth.rounded())
        let posterHeight = Int((Double(posterWidth) * 1.5).rounded())
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up))),
            posterURL: viewModel.posterURL(width: posterImageWidth, height: posterHeight),
            titleArtworkURL: viewModel.titleLogoURL(width: Int((containerWidth * 0.45).rounded(.up)), height: 128),
            title: details.title,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            posterWidth: CGFloat(posterWidth)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                metadataTagline(details)
                heroMetadata(details)
            }
        } actions: {
            actionButtons(details)
        }
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            details.year.map(String.init),
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

        if let director = viewModel.directorText {
            Text("Directed by \(director)")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.76))
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

    // MARK: - Actions

    @ViewBuilder
    private func actionButtons(_ details: PlexMediaDetails) -> some View {
        let layout = sizeClass == .regular
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 12))

        layout {
            Button {
                guard !viewModel.isUsingCachedData || viewModel.isPlayableOffline else { return }
                Task { await playback.play(ratingKey: details.ratingKey) }
            } label: {
                DetailHeroPrimaryActionButtonLabel(
                    title: viewModel.formattedResume.map { "Resume from \($0)" } ?? "Play",
                    systemImage: "play.fill",
                    fillsWidth: usesFullWidthActionButtons
                )
            }
            #if os(tvOS)
            .buttonStyle(.glassProminent)
            .tint(Color.duskAccent)
            #else
            .duskSuppressTVOSButtonChrome()
            #endif
            .disabled(viewModel.isUsingCachedData && !viewModel.isPlayableOffline)
            .contextMenu {
                if !viewModel.isUsingCachedData || viewModel.isPlayableOffline {
                    PlayVersionContextMenu(versions: details.media) { version in
                        Task { await playback.playVersion(ratingKey: details.ratingKey, mediaID: version.id) }
                    }
                }
            }

            DownloadActionButton(
                ratingKey: details.ratingKey,
                type: .movie,
                fillsWidth: usesFullWidthActionButtons
            )

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
            .duskTVOSFocusEffectShape(Capsule())
        }
    }

    private var usesFullWidthActionButtons: Bool {
        usesFullWidthDetailActionButtons(for: sizeClass)
    }

    // MARK: - Summary

    @ViewBuilder
    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synopsis")
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)

            Text(summary)
                .font(.body)
                .foregroundStyle(Color.duskTextSecondary)
                .lineSpacing(4)
        }
    }

    // MARK: - Media Info

    @ViewBuilder
    private func mediaInfoSection() -> some View {
        if let info = viewModel.mediaInfo {
            VStack(alignment: .leading, spacing: 8) {
                Text("Media")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)

                Text(info)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
    }
}
