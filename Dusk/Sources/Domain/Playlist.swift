import Foundation

/// A Plex playlist (`GET /playlists`). Every playlist lives on one server and
/// belongs to the signed-in (Home) user; its items can only come from that
/// server. Dusk shows video playlists only.
struct Playlist: Sendable, Identifiable, Hashable {
    /// Server-scoped identity; see `MediaItemID`.
    var id: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    /// Stamped by the provider mapper.
    let serverID: String?

    let itemID: String
    let title: String
    let summary: String?
    /// Filled from a saved filter, which only Plex Web can edit. Plex rejects
    /// adding, removing and moving its items (HTTP 400).
    let smart: Bool
    let playlistType: String?
    /// Plex's 2×2 mosaic of the first items' art.
    let composite: String?
    let thumb: String?
    /// Total runtime in milliseconds. (The `/items` container reports it in
    /// seconds — never read it from there.)
    let duration: Int?
    let episodeCount: Int?
    let playCount: Int?
    let lastPlayedAt: Int?
    let addedAt: Int?
    let updatedAt: Int?

    init(
        serverID: String?,
        itemID: String,
        title: String,
        summary: String? = nil,
        smart: Bool = false,
        playlistType: String? = "video",
        composite: String? = nil,
        thumb: String? = nil,
        duration: Int? = nil,
        episodeCount: Int? = nil,
        playCount: Int? = nil,
        lastPlayedAt: Int? = nil,
        addedAt: Int? = nil,
        updatedAt: Int? = nil
    ) {
        self.serverID = serverID
        self.itemID = itemID
        self.title = title
        self.summary = summary
        self.smart = smart
        self.playlistType = playlistType
        self.composite = composite
        self.thumb = thumb
        self.duration = duration
        self.episodeCount = episodeCount
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    var isVideo: Bool { playlistType == "video" }

    /// The mosaic, or the playlist's own art when Plex sends one instead.
    var artworkPath: String? { composite ?? thumb }

    func renamed(_ newTitle: String) -> Playlist {
        Playlist(
            serverID: serverID, itemID: itemID, title: newTitle, summary: summary,
            smart: smart, playlistType: playlistType, composite: composite, thumb: thumb,
            duration: duration, episodeCount: episodeCount, playCount: playCount,
            lastPlayedAt: lastPlayedAt, addedAt: addedAt, updatedAt: updatedAt
        )
    }

    static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.episodeCount == rhs.episodeCount
            && lhs.duration == rhs.duration && lhs.composite == rhs.composite
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// One entry of a playlist (`GET /playlists/{id}/items`): the item's normal
/// metadata plus the `playlistItemID` every edit is keyed on. Smart playlists
/// send no `playlistItemID` (their items cannot be edited), and the same item
/// may appear twice in a regular one, so entries are told apart by it.
struct PlaylistEntry: Sendable, Identifiable, Hashable {
    let playlistItemID: Int?
    let item: MediaItem

    /// Unique within one playlist listing.
    var id: String { playlistItemID.map(String.init) ?? item.id.storageKey }

    init(playlistItemID: Int?, item: MediaItem) {
        self.playlistItemID = playlistItemID
        self.item = item
    }

    static func == (lhs: PlaylistEntry, rhs: PlaylistEntry) -> Bool {
        lhs.id == rhs.id && lhs.item == rhs.item
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// What `PUT /playlists/{id}/items` reports: Plex expands a show or season
/// into its episodes and leaves out ones already in the playlist, so the two
/// counts can differ.
struct PlexPlaylistAddResult: Sendable, Equatable {
    let added: Int
    let requested: Int
}
