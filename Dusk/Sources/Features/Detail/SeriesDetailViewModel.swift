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
    let entryID: MediaItemID

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
        id: MediaItemID,
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
    var anchorEpisode: Episode? {
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
            await openSeason(id: MediaItemID(serverID: episode.serverID ?? serverID, ratingKey: seasonKey))
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

    /// Re-anchors the page on an episode that played after the player moved on
    /// from where the page started it (Up Next / Next Episode), opening its
    /// season when the run crossed into another one. Returns false when the
    /// episode is not part of this show, leaving the page alone.
    func follow(playedEpisode episode: MediaDetails) async -> Bool {
        guard episode.type == .episode,
              let seasonKey = episode.parentRatingKey,
              let showKey = season?.showID?.ratingKey ?? show?.id.ratingKey,
              episode.grandparentRatingKey == showKey,
              episode.serverID == nil || season?.serverID == nil || episode.serverID == season?.serverID else {
            return false
        }
        entryEpisodeKey = episode.ratingKey
        if seasonKey != season?.ratingKey {
            await openSeason(id: MediaItemID(serverID: episode.serverID ?? serverID, ratingKey: seasonKey))
        }
        return season?.ratingKey == seasonKey
    }

    func selectSeason(_ season: Season) async {
        guard season.ratingKey != selectedSeasonKey else { return }
        await openSeason(id: MediaItemID(serverID: season.serverID ?? serverID, ratingKey: season.ratingKey))
    }

    func toggleSeasonWatched() async {
        await season?.toggleSeasonWatched()
        await show?.refresh()
    }

    func setWatched(_ watched: Bool, for episode: Episode) async {
        await season?.setWatched(watched, for: episode)
        await show?.refresh()
    }

    func toggleWatched(for episode: Episode) async {
        await season?.toggleWatched(for: episode)
        await show?.refresh()
    }

    func markSeason(_ season: Season, watched: Bool) async {
        await show?.markSeason(season, watched: watched)
        if season.ratingKey == self.season?.ratingKey {
            await self.season?.refresh()
        }
    }

    // MARK: - Loading

    private func openSeason(id: MediaItemID) async {
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
        let show = makeShowModel(id: MediaItemID(serverID: season?.serverID ?? serverID, ratingKey: ratingKey))
        self.show = show
        await show.load()
    }

    private func makeShowModel(id: MediaItemID) -> ShowDetailViewModel {
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
    private func initialSeasonID(in show: ShowDetailViewModel) -> MediaItemID? {
        guard let season = Self.initialSeason(in: show.visibleSeasons) else { return nil }
        return MediaItemID(serverID: season.serverID ?? show.serverID, ratingKey: season.ratingKey)
    }

    private static func initialSeason(in seasons: [Season]) -> Season? {
        let regular = seasons.filter { $0.index > 0 }
        let candidates = regular.isEmpty ? seasons : regular
        return candidates.first(where: { !$0.isFullyWatched }) ?? candidates.first
    }

    /// The episode this page's Play button would start on for a show or season
    /// route (the season `initialSeasonID` opens, then its `nextEpisodeToPlay`),
    /// without loading the rest of the page. Play/Pause on a show or season
    /// card uses it (`TVQuickPlay`). Nil when there is nothing playable.
    static func playTarget(
        entry: Entry,
        id: MediaItemID,
        plexService: PlexService,
        downloadManager: DownloadManager?,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager?,
        prefersOfflineAvailability: Bool
    ) async -> Episode? {
        let serverID = id.serverID
            ?? downloadManager?.serverID(for: id)
            ?? plexService.pool.primary?.serverID
        let seasonID: MediaItemID
        switch entry {
        case .episode:
            return nil
        case .season:
            seasonID = id
        case .show:
            // Same sources and offline filter as `ShowDetailViewModel.load` /
            // `visibleSeasons`.
            var seasons: [Season]
            var isCached = false
            do {
                seasons = try await plexService.getSeasons(showKey: id.ratingKey, serverID: serverID)
            } catch {
                seasons = downloadManager?.cachedSeasons(show: id) ?? []
                isCached = true
            }
            seasons.sort { $0.index < $1.index }
            if DownloadsFeature.isVisible, isCached, let downloadManager {
                seasons = seasons.filter { downloadManager.hasDownloadedEpisodes(season: $0.id) }
            }
            guard let season = initialSeason(in: seasons) else { return nil }
            seasonID = MediaItemID(serverID: season.serverID ?? serverID, ratingKey: season.ratingKey)
        }

        let season = SeasonDetailViewModel(
            id: seasonID,
            plexService: plexService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager,
            prefersOfflineAvailability: prefersOfflineAvailability
        )
        await season.load()
        guard let episode = season.nextEpisodeToPlay,
              !season.constrainsPlaybackToOfflineAvailability || season.isPlayableOffline(episode) else {
            return nil
        }
        return episode
    }

    private func entryEpisodeDetails() async -> MediaDetails? {
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
