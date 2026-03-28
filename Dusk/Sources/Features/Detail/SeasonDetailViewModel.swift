import Foundation

@MainActor
@Observable
final class SeasonDetailViewModel {
    private let plexService: PlexService
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
    private(set) var episodes: [PlexEpisode] = []
    private(set) var nextEpisodeDetails: PlexMediaDetails?
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

    var nextEpisodeRoute: AppNavigationRoute? {
        guard let nextEpisodeToPlay else { return nil }
        return .media(type: .episode, ratingKey: nextEpisodeToPlay.ratingKey)
    }

    var nextEpisodeMenuLabel: String {
        guard let episode = nextEpisodeToPlay else { return "Go to Episode" }
        return MediaTextFormatter.seasonEpisodeLabel(
            season: nil,
            episode: episode.index,
            separator: " "
        ).map { "Go to \($0)" } ?? "Go to Episode"
    }

    var nextEpisodePlayableVersions: [PlexMedia] {
        nextEpisodeDetails?.media.filter { !$0.parts.isEmpty } ?? []
    }

    private func reload() async {
        isLoading = true
        error = nil

        do {
            // Context-menu navigation can create transient view/task lifetimes here.
            // Keeping these requests sequential avoids the async-let runtime abort seen in TestFlight.
            let loadedDetails = try await plexService.getMediaDetails(ratingKey: ratingKey)
            let loadedEpisodes = try await plexService.getEpisodes(seasonKey: ratingKey)
            details = loadedDetails
            episodes = loadedEpisodes.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            await loadNextEpisodeDetails()
        } catch {
            self.error = error.localizedDescription
            nextEpisodeDetails = nil
        }

        isLoading = false
    }

    private func loadNextEpisodeDetails() async {
        guard let nextEpisodeToPlay else {
            nextEpisodeDetails = nil
            return
        }

        do {
            nextEpisodeDetails = try await plexService.getMediaDetails(ratingKey: nextEpisodeToPlay.ratingKey)
        } catch {
            nextEpisodeDetails = nil
        }
    }
}
