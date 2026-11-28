import Foundation

/// What the player knows about an item it may play next: enough for the Up
/// Next poster/screen, the Previous / Next controls and the loading cover,
/// without another metadata round-trip. Built from the episode lookup
/// (`Episode`) or from a playlist's own item list (`MediaItem`).
///
/// The field names follow `Episode` so the Up Next views read the same
/// for an episode and a playlist entry; movies simply leave the season and
/// episode numbers empty.
struct PlaybackQueueItem: Sendable, Identifiable, Equatable {
    let id: MediaItemID
    let type: MediaKind
    let subtype: String?
    let title: String
    let summary: String?
    let year: Int?
    let editionTitle: String?

    /// Episode numbering and its show.
    let index: Int?
    let parentIndex: Int?
    let grandparentTitle: String?

    let thumb: String?
    let art: String?
    let grandparentThumb: String?

    let duration: Int?
    let viewOffset: Int?
    let isWatched: Bool

    var serverID: String? { id.serverID }
    var ratingKey: String { id.ratingKey }

    init(
        id: MediaItemID,
        type: MediaKind,
        subtype: String? = nil,
        title: String,
        summary: String? = nil,
        year: Int? = nil,
        editionTitle: String? = nil,
        index: Int? = nil,
        parentIndex: Int? = nil,
        grandparentTitle: String? = nil,
        thumb: String? = nil,
        art: String? = nil,
        grandparentThumb: String? = nil,
        duration: Int? = nil,
        viewOffset: Int? = nil,
        isWatched: Bool = false
    ) {
        self.id = id
        self.type = type
        self.subtype = subtype
        self.title = title
        self.summary = summary
        self.year = year
        self.editionTitle = editionTitle
        self.index = index
        self.parentIndex = parentIndex
        self.grandparentTitle = grandparentTitle
        self.thumb = thumb
        self.art = art
        self.grandparentThumb = grandparentThumb
        self.duration = duration
        self.viewOffset = viewOffset
        self.isWatched = isWatched
    }

    init(episode: Episode) {
        self.init(
            id: episode.id,
            type: .episode,
            title: episode.title,
            summary: episode.summary,
            year: episode.year,
            index: episode.index,
            parentIndex: episode.parentIndex,
            grandparentTitle: episode.grandparentTitle,
            thumb: episode.thumb,
            art: episode.art,
            grandparentThumb: episode.grandparentThumb,
            duration: episode.duration,
            viewOffset: episode.viewOffset,
            isWatched: episode.isWatched
        )
    }

    init(item: MediaItem) {
        self.init(
            id: item.id,
            type: item.type,
            subtype: item.subtype,
            title: item.title,
            summary: item.summary,
            year: item.year,
            editionTitle: item.editionTitle,
            index: item.type == .episode ? item.index : nil,
            parentIndex: item.type == .episode ? item.parentIndex : nil,
            grandparentTitle: item.type == .episode ? item.grandparentTitle : nil,
            thumb: item.thumb,
            art: item.art,
            grandparentThumb: item.grandparentThumb,
            duration: item.duration,
            viewOffset: item.viewOffset,
            isWatched: (item.viewCount ?? 0) > 0
        )
    }

    init(details: MediaDetails) {
        let isEpisode = details.type == .episode
        self.init(
            id: details.id,
            type: details.type,
            subtype: details.subtype,
            title: details.title,
            summary: details.summary,
            year: details.year,
            editionTitle: details.editionTitle,
            index: isEpisode ? details.index : nil,
            parentIndex: isEpisode ? details.parentIndex : nil,
            grandparentTitle: isEpisode ? details.grandparentTitle : nil,
            thumb: details.thumb,
            art: details.art,
            grandparentThumb: details.grandparentThumb,
            duration: details.duration,
            viewOffset: details.viewOffset,
            isWatched: (details.viewCount ?? 0) > 0
        )
    }

    var isEpisode: Bool { type == .episode }

    /// The resume offset a queue session hands playback as its fallback.
    /// Never a forced start position: the session decides from fresh details
    /// (and, for a download, pending offline progress), so a finished item
    /// starts over because Plex cleared its offset, and a rewatch that began
    /// since the list was read still resumes. A watched item contributes no
    /// fallback, so a stale offset in the list can never resume it near its
    /// end.
    var queueResumeFallbackOffset: Int? {
        isWatched ? nil : viewOffset
    }

    /// The 16:9 still Up Next shows: an episode's own frame, a movie's
    /// backdrop (its `thumb` is a 2:3 poster).
    var upNextStillPath: String? {
        isEpisode ? thumb ?? art ?? grandparentThumb : art ?? thumb
    }

    /// Whether the still may give an unwatched episode away (spoiler blur).
    var hasUnwatchedEpisodeStill: Bool {
        isEpisode && thumb != nil && !isWatched
    }

    /// `S2 · E4` for an episode, the year (and edition) for anything else.
    var upNextDetailLabel: String? {
        upNextDetailLabel(compact: false)
    }

    /// `compact` uses `S2 · E4`, for lines that also name the show.
    func upNextDetailLabel(compact: Bool) -> String? {
        if isEpisode {
            return compact
                ? MediaTextFormatter.compactSeasonEpisodeLabel(season: parentIndex, episode: index)
                : MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index)
        }
        return MediaTextFormatter.joinedWithEdition(year.map(String.init), edition: editionTitle)
    }

    /// Whether Dusk can play this kind of item at all. A video playlist only
    /// holds movies, episodes and clips, but Plex lets anything in.
    var isPlayableKind: Bool {
        switch type {
        case .movie, .episode, .clip: true
        default: false
        }
    }
}

/// A fixed list of items being played through in order, with the position of
/// the one playing. Built when a playlist starts (in playlist order, or
/// shuffled once for the session) and owned by `PlaybackCoordinator` for the
/// life of the player cover.
///
/// Ordinary playback has no queue at all: Up Next keeps resolving the next
/// episode of the show (`PlaybackCoordinator.resolveUpNext`), so a session
/// that never started from a playlist behaves exactly as it always did. A
/// queue session never falls back to the show's next episode — the playlist
/// wins, and its end ends playback.
struct PlaybackQueue: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        /// A Plex playlist, by its server-scoped id and title.
        case playlist(id: MediaItemID, title: String)
        /// A list of videos on screen — a Videos library or folder, a
        /// collection — in the order it is shown.
        case list(title: String)
    }

    let source: Source
    let isShuffled: Bool
    private(set) var items: [PlaybackQueueItem]
    /// Index into `items` of the item now playing (or being started).
    private(set) var position: Int
    /// Items found to be gone from the server since the list was read (their
    /// metadata no longer resolves). Skipped by `next`/`previous`.
    private(set) var unavailableIDs: Set<MediaItemID> = []

    init(source: Source, items: [PlaybackQueueItem], position: Int = 0, isShuffled: Bool = false) {
        self.source = source
        self.items = items
        self.position = min(max(position, 0), max(items.count - 1, 0))
        self.isShuffled = isShuffled
    }

    /// A playlist in its own order, starting at `startIndex`. Items Dusk
    /// cannot play are dropped up front so positions never point at them.
    static func playlist(
        id: MediaItemID,
        title: String,
        items: [PlaybackQueueItem],
        startIndex: Int = 0
    ) -> PlaybackQueue? {
        ordered(source: .playlist(id: id, title: title), items: items, startIndex: startIndex)
    }

    /// A list of videos in its on-screen order, starting at `startIndex`.
    static func list(title: String, items: [PlaybackQueueItem], startIndex: Int) -> PlaybackQueue? {
        ordered(source: .list(title: title), items: items, startIndex: startIndex)
    }

    /// `startIndex` is an occurrence, not an item: a playlist can hold the
    /// same title twice, so the position is counted through the filter
    /// instead of looked up by id.
    private static func ordered(source: Source, items: [PlaybackQueueItem], startIndex: Int) -> PlaybackQueue? {
        let playable = items.filter(\.isPlayableKind)
        guard !playable.isEmpty else { return nil }
        let clampedStart = min(max(startIndex, 0), items.count)
        let position = items[..<clampedStart].filter(\.isPlayableKind).count
        return PlaybackQueue(source: source, items: playable, position: min(position, playable.count - 1))
    }

    /// A playlist in a random order fixed for the session, starting at its
    /// first (random) item.
    static func shuffledPlaylist<G: RandomNumberGenerator>(
        id: MediaItemID,
        title: String,
        items: [PlaybackQueueItem],
        using generator: inout G
    ) -> PlaybackQueue? {
        let playable = items.filter(\.isPlayableKind)
        guard !playable.isEmpty else { return nil }
        return PlaybackQueue(
            source: .playlist(id: id, title: title),
            items: playable.shuffled(using: &generator),
            position: 0,
            isShuffled: true
        )
    }

    static func shuffledPlaylist(id: MediaItemID, title: String, items: [PlaybackQueueItem]) -> PlaybackQueue? {
        var generator = SystemRandomNumberGenerator()
        return shuffledPlaylist(id: id, title: title, items: items, using: &generator)
    }

    var title: String {
        switch source {
        case let .playlist(_, title), let .list(title): title
        }
    }

    var current: PlaybackQueueItem? {
        items.indices.contains(position) ? items[position] : nil
    }

    /// The next item that can play after the current one, with its index.
    /// `isPlayable` is the caller's availability rule (online, or downloaded
    /// while the item's server is unreachable).
    func next(isPlayable: (PlaybackQueueItem) -> Bool = { _ in true }) -> (index: Int, item: PlaybackQueueItem)? {
        guard position + 1 < items.count else { return nil }
        for index in (position + 1)..<items.count where isEligible(items[index], isPlayable) {
            return (index, items[index])
        }
        return nil
    }

    func previous(isPlayable: (PlaybackQueueItem) -> Bool = { _ in true }) -> (index: Int, item: PlaybackQueueItem)? {
        guard position > 0 else { return nil }
        for index in stride(from: position - 1, through: 0, by: -1) where isEligible(items[index], isPlayable) {
            return (index, items[index])
        }
        return nil
    }

    mutating func move(to index: Int) {
        guard items.indices.contains(index) else { return }
        position = index
    }

    /// Swaps in fresher metadata for the same item (watch state read after
    /// the list was). A different item at that index is left alone.
    mutating func replaceItem(at index: Int, with item: PlaybackQueueItem) {
        guard items.indices.contains(index), items[index].id == item.id else { return }
        items[index] = item
    }

    mutating func markUnavailable(_ id: MediaItemID) {
        unavailableIDs.insert(id)
    }

    private func isEligible(_ item: PlaybackQueueItem, _ isPlayable: (PlaybackQueueItem) -> Bool) -> Bool {
        !unavailableIDs.contains(item.id) && isPlayable(item)
    }
}

