import Foundation

/// A Plex playlist (`GET /playlists`). Every playlist lives on one server and
/// belongs to the signed-in (Home) user; its items can only come from that
/// server. Dusk shows video playlists only.
struct Playlist: Decodable, Sendable, Identifiable, Hashable {
    /// Server-scoped identity; see `MediaItemID`.
    var id: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    /// Stamped by `ServerPool.decoder(for:)`.
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
    let leafCount: Int?
    let viewCount: Int?
    let lastViewedAt: Int?
    let addedAt: Int?
    let updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case itemID = "ratingKey", title, summary, smart, playlistType, composite, thumb
        case duration, leafCount, viewCount, lastViewedAt, addedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = decoder.duskServerID
        itemID = try container.decode(String.self, forKey: .itemID)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)?.nilIfEmpty
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .smart) {
            smart = value
        } else if let value = try? container.decodeIfPresent(Int.self, forKey: .smart) {
            smart = value != 0
        } else {
            smart = (try? container.decodeIfPresent(String.self, forKey: .smart)) == "1"
        }
        playlistType = try container.decodeIfPresent(String.self, forKey: .playlistType)
        composite = try container.decodeIfPresent(String.self, forKey: .composite)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        leafCount = try container.decodeIfPresent(Int.self, forKey: .leafCount)
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        lastViewedAt = try container.decodeIfPresent(Int.self, forKey: .lastViewedAt)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }

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
        leafCount: Int? = nil,
        viewCount: Int? = nil,
        lastViewedAt: Int? = nil,
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
        self.leafCount = leafCount
        self.viewCount = viewCount
        self.lastViewedAt = lastViewedAt
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
            duration: duration, leafCount: leafCount, viewCount: viewCount,
            lastViewedAt: lastViewedAt, addedAt: addedAt, updatedAt: updatedAt
        )
    }

    static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.leafCount == rhs.leafCount
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
struct PlaylistEntry: Decodable, Sendable, Identifiable, Hashable {
    let playlistItemID: Int?
    let item: MediaItem

    /// Unique within one playlist listing.
    var id: String { playlistItemID.map(String.init) ?? item.id.storageKey }

    enum CodingKeys: String, CodingKey {
        case playlistItemID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(Int.self, forKey: .playlistItemID) {
            playlistItemID = value
        } else {
            playlistItemID = (try? container.decodeIfPresent(String.self, forKey: .playlistItemID)).flatMap { $0.flatMap(Int.init) }
        }
        item = try MediaItem(from: decoder)
    }

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
