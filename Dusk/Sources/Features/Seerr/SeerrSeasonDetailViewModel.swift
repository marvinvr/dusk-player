import Foundation

@MainActor
@Observable
final class SeerrSeasonDetailViewModel {
    let tvID: Int
    let seasonNumber: Int
    private let service: SeerrService

    private(set) var show: SeerrTVDetails?
    private(set) var season: SeerrSeasonDetails?
    private(set) var isLoading = false
    private(set) var isRequesting = false
    private(set) var error: String?
    var actionError: String?
    var showsRequestConfirmation = false

    init(tvID: Int, seasonNumber: Int, service: SeerrService) {
        self.tvID = tvID
        self.seasonNumber = seasonNumber
        self.service = service
    }

    var requestState: SeerrRequestState {
        service.requestState(mediaInfo: show?.mediaInfo, seasonNumber: seasonNumber)
    }

    var canRequest: Bool {
        requestState.canRequest && service.currentUser?.canRequest(.tv) == true
    }

    var requestTitle: String {
        if isRequesting { return "Requesting…" }
        guard canRequest else { return requestState.detailTitle }
        return service.publicSettings?.partialRequestsEnabled == false
            ? "Request Missing Seasons"
            : "Request Season \(seasonNumber)"
    }

    func backdropURL(width: Int) -> URL? {
        service.backdropURL(path: show?.backdropPath, width: width)
    }

    func stillURL(for episode: SeerrEpisode) -> URL? {
        service.stillURL(path: episode.stillPath)
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
        show = try await service.tvDetails(id: tvID)
        season = try await service.seasonDetails(tvID: tvID, seasonNumber: seasonNumber)
    }

    func request() async {
        guard canRequest, !isRequesting else { return }
        isRequesting = true
        actionError = nil
        defer { isRequesting = false }
        do {
            let requestedSeasons: SeerrRequestedSeasons =
                service.publicSettings?.partialRequestsEnabled == false
                ? .all
                : .numbers([seasonNumber])
            try await service.requestTV(id: tvID, seasons: requestedSeasons)
            try await refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
