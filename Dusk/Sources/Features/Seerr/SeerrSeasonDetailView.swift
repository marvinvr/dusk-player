import SwiftUI

struct SeerrSeasonDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var viewModel: SeerrSeasonDetailViewModel

    init(tvID: Int, seasonNumber: Int, service: SeerrService) {
        _viewModel = State(initialValue: SeerrSeasonDetailViewModel(
            tvID: tvID,
            seasonNumber: seasonNumber,
            service: service
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()
            if viewModel.isLoading && viewModel.season == nil {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.season == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else if let season = viewModel.season {
                content(season)
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await viewModel.load() }
        .alert(
            "Couldn’t Send Request",
            isPresented: Binding(
                get: { viewModel.actionError != nil },
                set: { if !$0 { viewModel.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.actionError ?? "")
        }
    }

    private func content(_ season: SeerrSeasonDetails) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeroSection(
                        backdropURL: viewModel.backdropURL(width: Int(geometry.size.width)),
                        title: season.name,
                        descriptionText: season.overview,
                        topInset: geometry.safeAreaInsets.top,
                        // The backdrop runs under side insets (iPhone landscape,
                        // iPhone Duo's vertical bar); the content stays inside them.
                        containerWidth: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                        backgroundLeadingInset: geometry.safeAreaInsets.leading,
                        heroBaseHeight: min(max(geometry.size.height * 0.62, 470), 680)
                    ) {
                        VStack(alignment: detailHeroContentAlignment(for: sizeClass), spacing: 6) {
                            if let showName = viewModel.show?.name {
                                Text(showName)
                                    .font(DuskFont.metadata(ios: .subheadline.weight(.medium)))
                                    .foregroundStyle(Color.primary.opacity(0.84))
                            }
                            if let metadata = viewModel.heroMetadata {
                                Text(metadata)
                                    .font(DuskFont.caption(ios: .caption))
                                    .foregroundStyle(Color.primary.opacity(0.76))
                            }
                        }
                    } actions: {
                        if viewModel.canRequest {
                            Button {
                                viewModel.showsRequestConfirmation = true
                            } label: {
                                DetailHeroPrimaryActionButtonLabel(
                                    title: viewModel.requestTitle,
                                    systemImage: "paperplane.fill",
                                    fillsWidth: usesFullWidthDetailActionButtons(for: sizeClass)
                                )
                            }
                            .detailHeroNativePrimaryButtonStyle()
                            .disabled(viewModel.isRequesting)
                            .confirmationDialog(
                                "Send this request?",
                                isPresented: $viewModel.showsRequestConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("Request") {
                                    Task { await viewModel.request() }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text(viewModel.requestTitle)
                            }
                        } else {
                            statusLabel
                        }
                    }
                    #if os(tvOS)
                    .focusSection()
                    #endif

                    if let overview = season.overview?.nilIfEmpty,
                       detailShowsSynopsisBelowHero(for: sizeClass) {
                        Text(overview)
                            .foregroundStyle(Color.duskTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)
                            .padding(.top, 28)
                    }

                    episodesSection(season.episodes ?? [])
                        .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)
                        .padding(.top, 36)
                        .padding(.bottom, 56)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                try? await viewModel.refresh()
            }
            .duskTVOSPageBackground()
        }
    }

    /// The request state when it can't be acted on. On tvOS it is a focus
    /// stop that does nothing when selected: a season with no episodes yet
    /// had nothing focusable at all, so focus sat on the tab bar over an
    /// empty-looking page.
    @ViewBuilder
    private var statusLabel: some View {
        #if os(tvOS)
        Button(action: {}) {
            DetailHeroPrimaryActionButtonLabel(
                title: viewModel.requestTitle,
                systemImage: viewModel.requestState.systemImage
            )
        }
        .detailHeroNativePrimaryButtonStyle()
        #else
        DetailHeroStatusActionLabel(
            title: viewModel.requestTitle,
            systemImage: viewModel.requestState.systemImage,
            fillsWidth: usesFullWidthDetailActionButtons(for: sizeClass)
        )
        #endif
    }

    /// TMDB often lists a renewed season before any of its episodes; say so
    /// instead of leaving the page blank under the hero.
    private func episodesSection(_ episodes: [SeerrEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Episodes")
                .font(DuskFont.sectionHeader(ios: .title3.bold()))
            if episodes.isEmpty {
                Text("No episodes have been announced yet.")
                    .duskFont(tvOnly: DuskFont.TV.body)
                    .foregroundStyle(Color.duskTextSecondary)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(episodes) { episode in
                        episodeRow(episode)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// On tvOS each row is a focus stop: a season that cannot be requested
    /// has no button in the hero, and with nothing focusable focus stayed on
    /// the tab bar, the episodes could not be scrolled to, and Back left the
    /// app (#62). The rows do nothing when selected.
    @ViewBuilder
    private func episodeRow(_ episode: SeerrEpisode) -> some View {
        #if os(tvOS)
        Button(action: {}) {
            episodeRowContent(episode)
        }
        .buttonStyle(.card)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        #else
        episodeRowContent(episode)
        #endif
    }

    private func episodeRowContent(_ episode: SeerrEpisode) -> some View {
        HStack(spacing: 18) {
            DuskAsyncImage(
                url: viewModel.stillURL(for: episode)
            ) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Color.duskSurface
                        .overlay(Image(systemName: "film").foregroundStyle(Color.duskTextSecondary))
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(episode.name?.nilIfEmpty ?? "Episode \(episode.episodeNumber ?? 0)")
                    .font(DuskFont.rowTitle(ios: .headline))
                    .foregroundStyle(Color.duskTextPrimary)
                // An unnamed episode is already titled "Episode N".
                let caption = [
                    episode.name?.nilIfEmpty == nil ? nil : episode.episodeNumber.map { "Episode \($0)" },
                    SeerrSeasonDetailViewModel.airDateText(episode.airDate),
                ].compactMap { $0 }
                if !caption.isEmpty {
                    Text(caption.joined(separator: " · "))
                        .font(DuskFont.caption(ios: .caption))
                        .foregroundStyle(Color.duskTextSecondary)
                }
                if let overview = episode.overview?.nilIfEmpty {
                    Text(overview)
                        .font(DuskFont.caption(ios: .caption))
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
