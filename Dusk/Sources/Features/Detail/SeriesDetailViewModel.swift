#if os(tvOS)
import Foundation

/// tvOS has a single page per show: every show, season, and episode route lands
/// here. The page browses one season at a time (season pills pick which), so this
/// model composes the existing show model — seasons, Seerr gaps, watch state —
/// with a season model for the season on screen, instead of re-implementing
/// either one.
@MainActor
@Observable
final class SeriesDetailViewModel {
    /// What the route pointed at. It only decides which season opens first and,
    /// for an episode, which episode the page starts on.
    enum Entry {
        case show
        case season
        case episode
    }

    private let plexService: PlexService
    private let seerrService: SeerrService?
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    private let prefersOfflineAvailability: Bool
    let entry: Entry
    let entryID: PlexItemID

    /// Loaded after the first season is on screen for season/episode entries, so
    /// the pills are the only thing that waits on it.
    private(set) var show: ShowDetailViewModel?
    /// The season on screen. It is only swapped once the next season has loaded,
    /// so switching seasons never blanks the page.
    private(set) var season: SeasonDetailViewModel?
    /// The season the user picked. Moves ahead of `season` while it loads.
    private(set) var selectedSeasonKey: String?
    private(set) var isLoading = false
    private(set) var error: String?
    /// The episode an episode route asked for; the page starts on it when its
    /// season is the one on screen.
    private var entryEpisodeKey: String?

    init(
        entry: Entry,
        id: PlexItemID,
        plexService: PlexService,
        seerrService: SeerrService? = nil,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        self.entry = entry
        self.entryID = id
        self.plexService = plexService
        self.seerrService = seerrService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
        self.prefersOfflineAvailability = prefersOfflineAvailability
    }

    /// The route's server wins; see `SeasonDetailViewModel.serverID`.
    private var serverID: String? {
        entryID.serverID
            ?? downloadManager?.serverID(for: entryID)
            ?? plexService.pool.primary?.serverID
    }

    var isSwitchingSeason: Bool {
        selectedSeasonKey != nil && selectedSeasonKey != season?.ratingKey
    }

    /// Season pills are only worth a focus stop when there is a choice to make.
    var seasonItems: [ShowDetailViewModel.SeasonItem] {
        guard let items = show?.seasonItems, items.count > 1 else { return [] }
        return items
    }

    /// The episode the page starts on for the season on screen: the episode the
    /// route asked for, else the season's next-up episode.
    var anchorEpisode: PlexEpisode? {
        guard let season else { return nil }
        if let entryEpisodeKey,
           let episode = season.displayEpisodes.first(where: { $0.ratingKey == entryEpisodeKey }) {
            return episode
        }
        return season.nextEpisodeToPlay
    }

    func load() async {
        guard season == nil else { return }
        isLoading = true
        error = nil

        switch entry {
        case .show:
            let show = makeShowModel(id: entryID)
            self.show = show
            await show.load()
            if let seasonID = initialSeasonID(in: show) {
                await openSeason(id: seasonID)
            } else {
                error = show.error ?? "This show has no seasons."
            }
        case .season:
            await openSeason(id: entryID)
            await loadShow(ratingKey: season?.showID?.ratingKey)
        case .episode:
            guard let episode = await entryEpisodeDetails(),
                  let seasonKey = episode.parentRatingKey else {
                if error == nil {
                    error = "This episode could not be loaded."
                }
                break
            }
            entryEpisodeKey = episode.ratingKey
            await openSeason(id: PlexItemID(serverID: episode.serverID ?? serverID, ratingKey: seasonKey))
            await loadShow(ratingKey: episode.grandparentRatingKey ?? season?.showID?.ratingKey)
        }

        isLoading = false
    }

    func retry() async {
        guard season == nil else { return }
        show = nil
        selectedSeasonKey = nil
        await load()
    }

    func refresh() async {
        await season?.refresh()
        await show?.refresh()
    }

    func selectSeason(_ season: PlexSeason) async {
        guard season.ratingKey != selectedSeasonKey else { return }
        await openSeason(id: PlexItemID(serverID: season.serverID ?? serverID, ratingKey: season.ratingKey))
    }

    func toggleSeasonWatched() async {
        await season?.toggleSeasonWatched()
        await show?.refresh()
    }

    func setWatched(_ watched: Bool, for episode: PlexEpisode) async {
        await season?.setWatched(watched, for: episode)
        await show?.refresh()
    }

    func toggleWatched(for episode: PlexEpisode) async {
        await season?.toggleWatched(for: episode)
        await show?.refresh()
    }

    func markSeason(_ season: PlexSeason, watched: Bool) async {
        await show?.markSeason(season, watched: watched)
        if season.ratingKey == self.season?.ratingKey {
            await self.season?.refresh()
        }
    }

    // MARK: - Loading

    private func openSeason(id: PlexItemID) async {
        selectedSeasonKey = id.ratingKey
        let model = SeasonDetailViewModel(
            id: id,
            plexService: plexService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager,
            prefersOfflineAvailability: prefersOfflineAvailability
        )
        await model.load()

        // A later pick wins; drop this one if the user moved on while it loaded.
        guard selectedSeasonKey == id.ratingKey else { return }

        if model.details == nil {
            if season == nil {
                error = model.error ?? "This season could not be loaded."
            } else {
                // Keep the season that is already on screen rather than blanking it.
                selectedSeasonKey = season?.ratingKey
            }
            return
        }

        season = model
    }

    private func loadShow(ratingKey: String?) async {
        guard show == nil, let ratingKey else { return }
        let show = makeShowModel(id: PlexItemID(serverID: season?.serverID ?? serverID, ratingKey: ratingKey))
        self.show = show
        await show.load()
    }

    private func makeShowModel(id: PlexItemID) -> ShowDetailViewModel {
        ShowDetailViewModel(
            id: id,
            plexService: plexService,
            seerrService: seerrService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager,
            prefersOfflineAvailability: prefersOfflineAvailability
        )
    }

    /// A show route opens on the first regular season that still has something
    /// unwatched. Specials sort first but are rarely where someone left off, so
    /// they only win when the show has nothing else.
    private func initialSeasonID(in show: ShowDetailViewModel) -> PlexItemID? {
        let seasons = show.visibleSeasons
        let regular = seasons.filter { $0.index > 0 }
        let candidates = regular.isEmpty ? seasons : regular
        guard let season = candidates.first(where: { !$0.isFullyWatched }) ?? candidates.first else {
            return nil
        }
        return PlexItemID(serverID: season.serverID ?? show.serverID, ratingKey: season.ratingKey)
    }

    private func entryEpisodeDetails() async -> PlexMediaDetails? {
        do {
            return try await plexService.getMediaDetails(
                ratingKey: entryID.ratingKey,
                serverID: serverID
            )
        } catch {
            if let cached = downloadManager?.cachedMediaDetails(for: entryID) {
                return cached
            }
            self.error = error.localizedDescription
            return nil
        }
    }
}
#endif
