import Foundation

@MainActor
@Observable
final class SeasonDetailViewModel {
    private let plexService: PlexService
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
    private(set) var episodes: [PlexEpisode] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(ratingKey: String, plexService: PlexService) {
        self.ratingKey = ratingKey
        self.plexService = plexService
    }

    func load() async {
        guard details == nil else { return }
        await reload()
    }

    func toggleWatched(for episode: PlexEpisode) async {
        do {
            try await plexService.setWatched(!episode.isWatched, ratingKey: episode.ratingKey)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    var showTitle: String? {
        details?.grandparentTitle ?? episodes.first?.grandparentTitle
    }

    var showRatingKey: String? {
        details?.parentRatingKey ?? episodes.first?.grandparentRatingKey
    }

    var episodeCountText: String? {
        let count = details?.leafCount ?? details?.childCount ?? episodes.count
        return MediaTextFormatter.episodeCount(count)
    }

    var watchedEpisodeCountText: String? {
        let viewedCount = details?.viewedLeafCount ?? episodes.filter(\.isWatched).count
        return MediaTextFormatter.watchedCount(viewedCount)
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        plexService.imageURL(for: details?.art, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        plexService.imageURL(for: details?.thumb, width: width, height: height)
    }

    func episodeImageURL(_ episode: PlexEpisode, width: Int, height: Int) -> URL? {
        plexService.imageURL(
            for: episode.thumb ?? episode.grandparentThumb,
            width: width,
            height: height
        )
    }

    func episodeSubtitle(_ episode: PlexEpisode) -> String? {
        [
            MediaTextFormatter.shortDuration(milliseconds: episode.duration),
            MediaTextFormatter.localizedAirDate(episode.originallyAvailableAt),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    }

    func episodeLabel(_ episode: PlexEpisode) -> String? {
        MediaTextFormatter.seasonEpisodeLabel(season: nil, episode: episode.index, separator: " ")
    }

    func progress(for episode: PlexEpisode) -> Double? {
        MediaTextFormatter.progress(durationMs: episode.duration, offsetMs: episode.viewOffset)
    }

    // MARK: - Play Next

    /// The episode the user would most likely want to play:
    /// first partially watched, then first unwatched, then first overall.
    var nextEpisodeToPlay: PlexEpisode? {
        episodes.first(where: \.isPartiallyWatched)
            ?? episodes.first(where: { !$0.isWatched })
            ?? episodes.first
    }

    var playButtonLabel: String {
        guard let ep = nextEpisodeToPlay else { return "Play" }
        let label = ep.index.map { "Episode \($0)" } ?? ep.title
        if ep.isPartiallyWatched {
            return "Resume · \(label)"
        }
        return "Play · \(label)"
    }

    private func reload() async {
        isLoading = true
        error = nil

        do {
            async let detailsRequest = plexService.getMediaDetails(ratingKey: ratingKey)
            async let episodesRequest = plexService.getEpisodes(seasonKey: ratingKey)
            let (loadedDetails, loadedEpisodes) = try await (detailsRequest, episodesRequest)
            details = loadedDetails
            episodes = loadedEpisodes.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
