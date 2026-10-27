import SwiftUI

/// Where a Watchlist title that is on none of the connected servers opens.
///
/// With Seerr connected it is Seerr's own detail page (Request), found
/// through the TMDB id in Plex's metadata. Otherwise, or when Plex has no
/// TMDB id for it, a light page from Plex's metadata: what it is, that it is
/// not on your servers, where it streams, and the Watchlist action in the
/// primary slot, since there is nothing to play.
struct WatchlistItemDetailView: View {
    @Environment(SeerrService.self) private var seerrService
    @State private var viewModel: WatchlistItemDetailViewModel

    init(entry: PlexWatchlistEntry, plexService: PlexService) {
        _viewModel = State(initialValue: WatchlistItemDetailViewModel(entry: entry, plexService: plexService))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if !viewModel.hasLoaded {
                FeatureLoadingView()
            } else if usesSeerr, let tmdbID = viewModel.entry.tmdbID {
                SeerrMediaDetailView(
                    mediaType: viewModel.entry.seerrMediaType,
                    mediaID: tmdbID,
                    service: seerrService,
                    watchlistEntry: viewModel.entry
                )
            } else {
                WatchlistInfoPage(viewModel: viewModel)
            }
        }
        .task { await viewModel.load() }
    }

    private var usesSeerr: Bool {
        seerrService.isAvailableForCurrentContext
    }
}

@MainActor
@Observable
final class WatchlistItemDetailViewModel {
    private(set) var entry: PlexWatchlistEntry
    private(set) var streamingServices: [String] = []
    private(set) var hasLoaded = false
    var actionError: String?

    private let plexService: PlexService

    init(entry: PlexWatchlistEntry, plexService: PlexService) {
        self.entry = entry
        self.plexService = plexService
    }

    /// The list entry is enough to show the page; full metadata (TMDB id,
    /// summary) and the services only add to it, and failing them is quiet.
    func load() async {
        guard !hasLoaded else { return }
        let ratingKey = entry.ratingKey
        async let metadata = try? plexService.getWatchlistMetadata(ratingKey: ratingKey)
        async let availabilities = try? plexService.getWatchlistAvailabilities(ratingKey: ratingKey)
        if let details = await metadata {
            entry = details
        }
        var seen = Set<String>()
        streamingServices = (await availabilities ?? [])
            .filter(\.isIncluded)
            .compactMap { $0.title?.nilIfEmpty }
            .filter { seen.insert($0).inserted }
        hasLoaded = true
    }

    var isWatchlisted: Bool? {
        plexService.watchlist.contains(guid: entry.guid)
    }

    func toggleWatchlist() async {
        do {
            try await WatchlistActions.toggle(entry: entry, match: nil, plexService: plexService)
        } catch {
            actionError = error.localizedDescription
        }
    }

    var metadataLine: String {
        let length: String? = switch entry.type {
        case .show: MediaTextFormatter.seasonCount(entry.childCount)
        default: MediaTextFormatter.compactDuration(milliseconds: entry.duration)
        }
        return [
            entry.year.map(String.init),
            entry.contentRating?.nilIfEmpty,
            length,
            entry.type == .show ? "TV Show" : "Movie",
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var availabilityLine: String {
        guard !streamingServices.isEmpty else { return "Not on your Plex servers" }
        return "Not on your Plex servers · \(streamingServices.prefix(4).joined(separator: ", "))"
    }

    var backdropURL: URL? {
        PlexWatchlistEntry.artworkURL(entry.art, width: 1280)
    }
}

private struct WatchlistInfoPage: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable var viewModel: WatchlistItemDetailViewModel

    private let horizontalPadding = DuskPosterMetrics.detailHorizontalPadding

    var body: some View {
        GeometryReader { geometry in
            // The backdrop runs under side insets (iPhone landscape, iPhone
            // Duo's vertical bar); the hero content stays inside them.
            let backgroundWidth = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            let leadingInset = geometry.safeAreaInsets.leading

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeroSection(
                        backdropURL: viewModel.backdropURL,
                        title: viewModel.entry.title,
                        descriptionText: viewModel.entry.summary,
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: backgroundWidth,
                        backgroundLeadingInset: leadingInset,
                        heroBaseHeight: min(max(geometry.size.height * 0.72, 520), 760)
                    ) {
                        VStack(alignment: detailHeroContentAlignment(for: sizeClass), spacing: 6) {
                            Text(viewModel.metadataLine)
                                .font(DuskFont.metadata(ios: .subheadline.weight(.medium)))
                                .foregroundStyle(Color.primary.opacity(0.78))
                            Text(viewModel.availabilityLine)
                                .font(DuskFont.caption(ios: .caption))
                                .foregroundStyle(Color.primary.opacity(0.72))
                        }
                    } actions: {
                        if let isWatchlisted = viewModel.isWatchlisted {
                            Button {
                                Task { await viewModel.toggleWatchlist() }
                            } label: {
                                DetailHeroPrimaryActionButtonLabel(
                                    title: WatchlistActions.menuTitle(isWatchlisted: isWatchlisted),
                                    systemImage: isWatchlisted ? "bookmark.slash" : "bookmark",
                                    fillsWidth: usesFullWidthDetailActionButtons(for: sizeClass)
                                )
                            }
                            .detailHeroNativePrimaryButtonStyle()
                        }
                    }
                    #if os(tvOS)
                    .focusSection()
                    #endif

                    if detailShowsSynopsisBelowHero(for: sizeClass),
                       let summary = viewModel.entry.summary?.nilIfEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Synopsis")
                                .font(DuskFont.sectionHeader(ios: .title3.bold()))
                            Text(summary)
                                .duskFont(tvOnly: DuskFont.TV.body)
                                .foregroundStyle(Color.duskTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 28)
                    }

                    Spacer(minLength: 56)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .duskTVOSPageBackground()
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .alert(
            "Couldn’t Update Watchlist",
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
}
