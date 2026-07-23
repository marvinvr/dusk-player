import Foundation

@MainActor
@Observable
final class SeerrMediaDetailViewModel {
    enum Details {
        case movie(SeerrMovieDetails)
        case tv(SeerrTVDetails)
    }

    let mediaType: SeerrMediaType
    let mediaID: Int
    private let service: SeerrService

    private(set) var details: Details?
    private(set) var isLoading = false
    private(set) var isRequesting = false
    private(set) var error: String?
    var actionError: String?
    var showsRequestConfirmation = false

    init(mediaType: SeerrMediaType, mediaID: Int, service: SeerrService) {
        self.mediaType = mediaType
        self.mediaID = mediaID
        self.service = service
    }

    var title: String {
        switch details {
        case .movie(let value): value.title
        case .tv(let value): value.name
        case nil: ""
        }
    }

    var overview: String? {
        switch details {
        case .movie(let value): value.overview
        case .tv(let value): value.overview
        case nil: nil
        }
    }

    var year: Int? {
        switch details {
        case .movie(let value): value.year
        case .tv(let value): value.year
        case nil: nil
        }
    }

    var rating: Double? {
        switch details {
        case .movie(let value): value.voteAverage
        case .tv(let value): value.voteAverage
        case nil: nil
        }
    }

    var genreText: String? {
        let genres: [SeerrGenre]?
        switch details {
        case .movie(let value): genres = value.genres
        case .tv(let value): genres = value.genres
        case nil: genres = nil
        }
        let value = genres?.map(\.name).joined(separator: " · ")
        return value?.nilIfEmpty
    }

    var runtimeText: String? {
        guard case .movie(let value) = details, let runtime = value.runtime else { return nil }
        let hours = runtime / 60
        let minutes = runtime % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var seasons: [SeerrSeasonSummary] {
        guard case .tv(let value) = details else { return [] }
        return value.seasons.filter {
            $0.seasonNumber > 0 || service.publicSettings?.enableSpecialEpisodes == true
        }
    }

    var mediaInfo: SeerrMediaInfo? {
        switch details {
        case .movie(let value): value.mediaInfo
        case .tv(let value): value.mediaInfo
        case nil: nil
        }
    }

    var requestState: SeerrRequestState {
        service.requestState(mediaInfo: mediaInfo)
    }

    var canRequest: Bool {
        let hasRequestableContent: Bool
        switch mediaType {
        case .movie:
            hasRequestableContent = requestState.canRequest
        case .tv:
            hasRequestableContent = seasons.contains {
                service.requestState(
                    mediaInfo: mediaInfo,
                    seasonNumber: $0.seasonNumber
                ).canRequest
            }
        }
        return hasRequestableContent && service.currentUser?.canRequest(mediaType) == true
    }

    var requestButtonTitle: String {
        if isRequesting { return "Requesting…" }
        return canRequest
            ? (mediaType == .movie ? "Request Movie" : "Request Missing Seasons")
            : requestState.detailTitle
    }

    func backdropURL(width: Int) -> URL? {
        let path: String?
        switch details {
        case .movie(let value): path = value.backdropPath
        case .tv(let value): path = value.backdropPath
        case nil: path = nil
        }
        return service.backdropURL(path: path, width: width)
    }

    func posterURL(for season: SeerrSeasonSummary, width: Int) -> URL? {
        service.posterURL(path: season.posterPath, width: width)
    }

    func seasonState(_ seasonNumber: Int) -> SeerrRequestState {
        service.requestState(mediaInfo: mediaInfo, seasonNumber: seasonNumber)
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            try await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async throws {
        switch mediaType {
        case .movie:
            details = .movie(try await service.movieDetails(id: mediaID))
        case .tv:
            details = .tv(try await service.tvDetails(id: mediaID))
        }
    }

    func request() async {
        guard canRequest, !isRequesting else { return }
        isRequesting = true
        actionError = nil
        defer { isRequesting = false }

        do {
            switch mediaType {
            case .movie:
                try await service.requestMovie(id: mediaID)
            case .tv:
                try await service.requestTV(id: mediaID, seasons: .all)
            }
            try await refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
