import SwiftUI

/// Loads the extras of one movie, show, season, or episode.
@MainActor
@Observable
final class DetailExtrasModel {
    private(set) var extras: [Extra] = []

    @ObservationIgnored private var loadedID: MediaItemID?

    /// - Parameter delay: waited before the request, so a row that follows
    ///   focus (the tvOS episode row) does not fetch for every card zapped past.
    func load(itemID: MediaItemID?, media: MediaService, delay: Duration = .zero) async {
        guard itemID != loadedID else { return }
        // Another title's extras must not linger while this one's load.
        loadedID = nil
        extras = []
        guard let itemID else { return }

        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard !Task.isCancelled else { return }

        // Offline or unreachable: no row, same as a title without extras, and
        // the next appearance asks again.
        guard let loaded = try? await media.getExtras(
            itemID: itemID.itemID,
            serverID: itemID.serverID
        ), !Task.isCancelled else { return }
        loadedID = itemID
        extras = loaded
    }

    func subtitle(for item: MediaItem) -> String? {
        extras.first { $0.id == item.id }?.cardSubtitle
    }

    /// The trailer the hero's Trailer button plays: the one Plex names as the
    /// title's primary extra, else the first trailer in Plex's order.
    func trailer(primaryExtraKey: String?) -> Extra? {
        let trailers = extras.filter { $0.kind == .trailer }
        if let primaryExtraKey,
           let primary = trailers.first(where: { primaryExtraKey.hasSuffix("/\($0.item.itemID)") }) {
            return primary
        }
        return trailers.first
    }

    func play(_ item: MediaItem, ownerTitle: String?, playback: PlaybackCoordinator) {
        let placeholder = PlaybackPlaceholder(
            title: item.title,
            subtitle: ownerTitle ?? subtitle(for: item),
            posterPath: item.preferredPoster?.locator,
            backdropPath: item.art ?? item.thumb,
            serverID: item.serverID
        )
        Task {
            await playback.play(
                id: item.id,
                resumeOffsetMilliseconds: item.resumeOffsetMs,
                resumeOffsetDurationMilliseconds: item.duration,
                placeholder: placeholder
            )
        }
    }
}

/// The 16:9 "Extras" row of a detail page: the title's trailers, featurettes,
/// deleted scenes, … Selecting one plays it through the normal clip path. The
/// row is absent when the title has no extras.
struct DetailExtrasShelf: View {
    @Environment(MediaService.self) private var media
    @Environment(PlaybackCoordinator.self) private var playback

    let itemID: MediaItemID?
    var title: String = "Extras"
    /// What the extras belong to; the player's loading screen shows it under
    /// the extra's own title.
    var ownerTitle: String?
    var topPadding: CGFloat = detailSectionSpacing
    var bottomPadding: CGFloat = 0
    var loadDelay: Duration = .zero

    @State private var model: DetailExtrasModel

    /// - Parameter model: pass the page's own model when its hero also reads
    ///   the extras (the Trailer button); the shelf still drives the load.
    init(
        itemID: MediaItemID?,
        title: String = "Extras",
        ownerTitle: String? = nil,
        topPadding: CGFloat = detailSectionSpacing,
        bottomPadding: CGFloat = 0,
        loadDelay: Duration = .zero,
        model: DetailExtrasModel? = nil
    ) {
        self.itemID = itemID
        self.title = title
        self.ownerTitle = ownerTitle
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.loadDelay = loadDelay
        _model = State(initialValue: model ?? DetailExtrasModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.extras.isEmpty {
                MediaItemActionCarouselSection(
                    title: title,
                    items: model.extras.map(\.item),
                    action: play,
                    posterWidth: DuskPosterMetrics.videoCarouselWidth,
                    imageAspectRatio: 16.0 / 9.0,
                    horizontalPadding: DuskPosterMetrics.detailHorizontalPadding,
                    subtitle: { model.subtitle(for: $0) },
                    posterURL: { item, width, height in
                        item.posterImageURL(media: media, width: width, height: height)
                    },
                    progress: { $0.posterProgress }
                ) { _ in
                    EmptyView()
                }
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
        .task(id: itemID) {
            await model.load(itemID: itemID, media: media, delay: loadDelay)
        }
    }

    private func play(_ item: MediaItem) {
        model.play(item, ownerTitle: ownerTitle, playback: playback)
    }
}

/// The hero's Trailer action: an icon-only secondary button that plays the
/// title's trailer extra, absent while the extras load or when there is none.
/// Without a trailer extra, a web-only trailer (`remoteTrailerURL`) opens in
/// its app or the browser; tvOS has no browser, so there it stays hidden.
struct DetailTrailerHeroButton: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.openURL) private var openURL

    let model: DetailExtrasModel
    let primaryExtraKey: String?
    let ownerTitle: String?
    var remoteTrailerURL: URL? = nil

    var body: some View {
        if let trailer = model.trailer(primaryExtraKey: primaryExtraKey) {
            Button {
                model.play(trailer.item, ownerTitle: ownerTitle, playback: playback)
            } label: {
                DetailHeroSecondaryIconLabel(systemImage: "movieclapper", title: "Play Trailer")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel("Play Trailer")
        } else if let remoteTrailerURL = openableRemoteTrailerURL {
            Button {
                openURL(remoteTrailerURL)
            } label: {
                DetailHeroSecondaryIconLabel(systemImage: "movieclapper", title: "Play Trailer")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel("Play Trailer")
        }
    }

    private var openableRemoteTrailerURL: URL? {
        #if os(tvOS)
        nil
        #else
        remoteTrailerURL
        #endif
    }
}
