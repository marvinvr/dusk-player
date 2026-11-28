import Foundation

/// A playlist row of `GET /playlists` (and `/playlists/{id}`, and the
/// `POST /playlists` answer). Mapped to `Playlist` by `PlexUserContentMapper`.
struct PlexPlaylistDTO: Decodable, Sendable {
    let itemID: String
    let title: String
    let summary: String?
    let smart: Bool
    let playlistType: String?
    let composite: String?
    let thumb: String?
    /// Milliseconds here; the `/items` container reports seconds.
    let duration: Int?
    let episodeCount: Int?
    let playCount: Int?
    let lastPlayedAt: Int?
    let addedAt: Int?
    let updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case itemID = "ratingKey", title, summary, smart, playlistType, composite, thumb
        case duration, episodeCount = "leafCount", playCount = "viewCount", lastPlayedAt = "lastViewedAt", addedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        episodeCount = try container.decodeIfPresent(Int.self, forKey: .episodeCount)
        playCount = try container.decodeIfPresent(Int.self, forKey: .playCount)
        lastPlayedAt = try container.decodeIfPresent(Int.self, forKey: .lastPlayedAt)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }
}

/// One row of `GET /playlists/{id}/items`: the item's normal metadata plus the
/// `playlistItemID` every edit is keyed on (absent for smart playlists).
struct PlexPlaylistEntryDTO: Decodable, Sendable {
    let playlistItemID: Int?
    /// The same row decoded as a library item. It reads the server stamp from
    /// the decoder, so this DTO must be decoded through `decodeJSON(…, serverID:)`.
    let item: MediaItem

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
}
