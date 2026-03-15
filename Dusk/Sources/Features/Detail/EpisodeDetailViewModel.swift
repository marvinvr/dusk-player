import Foundation

@MainActor
@Observable
final class EpisodeDetailViewModel {
    private let plexService: PlexService
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
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

    func toggleWatched() async {
        guard let details else { return }

        do {
            try await plexService.setWatched(!isWatched(details), ratingKey: details.ratingKey)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    var seasonLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: details?.parentIndex, episode: nil)
    }

    var seasonRatingKey: String? {
        details?.parentRatingKey
    }

    var episodeLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: nil, episode: details?.index)
    }

    var showTitle: String? {
        details?.grandparentTitle
    }

    var showRatingKey: String? {
        details?.grandparentRatingKey
    }

    var formattedDuration: String? {
        MediaTextFormatter.shortDuration(milliseconds: details?.duration)
    }

    var isWatched: Bool {
        guard let details else { return false }
        return isWatched(details)
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        plexService.imageURL(for: details?.thumb ?? details?.art, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        plexService.imageURL(
            for: details?.parentThumb ?? details?.grandparentThumb ?? details?.thumb,
            width: width,
            height: height
        )
    }

    private func reload() async {
        isLoading = true
        error = nil

        do {
            details = try await plexService.getMediaDetails(ratingKey: ratingKey)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func isWatched(_ details: PlexMediaDetails) -> Bool {
        guard let viewCount = details.viewCount else { return false }
        return viewCount > 0
    }
}
