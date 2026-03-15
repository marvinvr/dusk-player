import Foundation

@MainActor
@Observable
final class ShowDetailViewModel {
    private let plexService: PlexService
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
    private(set) var seasons: [PlexSeason] = []
    private(set) var nextEpisode: PlexEpisode?
    private(set) var isLoading = false
    private(set) var error: String?

    init(ratingKey: String, plexService: PlexService) {
        self.ratingKey = ratingKey
        self.plexService = plexService
    }

    func load() async {
        guard details == nil else { return }
        isLoading = true
        error = nil

        do {
            try await reload()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func markSeason(_ season: PlexSeason, watched: Bool) async {
        do {
            try await plexService.setWatched(watched, ratingKey: season.ratingKey)
            try await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    var genreText: String? {
        guard let genres = details?.genres, !genres.isEmpty else { return nil }
        return genres.prefix(3).map(\.tag).joined(separator: ", ")
    }

    var seasonCountText: String? {
        if let count = details?.childCount, count > 0 {
            return MediaTextFormatter.seasonCount(count)
        }

        return MediaTextFormatter.seasonCount(seasons.count)
    }

    var episodeCountText: String? {
        MediaTextFormatter.episodeCount(details?.leafCount)
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        plexService.imageURL(for: details?.art, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        plexService.imageURL(for: details?.thumb, width: width, height: height)
    }

    func seasonPosterURL(_ season: PlexSeason, width: Int, height: Int) -> URL? {
        plexService.imageURL(
            for: season.thumb ?? season.parentThumb ?? season.art,
            width: width,
            height: height
        )
    }

    func seasonSubtitle(_ season: PlexSeason) -> String? {
        MediaTextFormatter.episodeCount(season.leafCount)
    }

    func seasonProgress(_ season: PlexSeason) -> Double? {
        guard let total = season.leafCount,
              let viewed = season.viewedLeafCount,
              total > 0,
              viewed > 0 else { return nil }
        return Double(viewed) / Double(total)
    }

    // MARK: - Play Next

    var playButtonLabel: String {
        guard let ep = nextEpisode else { return "Play" }
        let label = MediaTextFormatter.seasonEpisodeLabel(
            season: ep.parentIndex,
            episode: ep.index
        ) ?? "Episode \(ep.index ?? 1)"
        if ep.isPartiallyWatched {
            return "Resume · \(label)"
        }
        return "Play · \(label)"
    }

    private func reload() async throws {
        async let detailsRequest = plexService.getMediaDetails(ratingKey: ratingKey)
        async let seasonsRequest = plexService.getSeasons(showKey: ratingKey)
        let (loadedDetails, loadedSeasons) = try await (detailsRequest, seasonsRequest)
        details = loadedDetails
        seasons = loadedSeasons.sorted { $0.index < $1.index }
        await resolveNextEpisode()
    }

    private func resolveNextEpisode() async {
        // Find first season that isn't fully watched
        let targetSeason = seasons.first(where: { !$0.isFullyWatched })
            ?? seasons.first

        guard let season = targetSeason else {
            nextEpisode = nil
            return
        }

        do {
            let episodes = try await plexService.getEpisodes(seasonKey: season.ratingKey)
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            nextEpisode = episodes.first(where: \.isPartiallyWatched)
                ?? episodes.first(where: { !$0.isWatched })
                ?? episodes.first
        } catch {
            nextEpisode = nil
        }
    }
}
