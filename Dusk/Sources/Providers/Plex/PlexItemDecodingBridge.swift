import Foundation

// Transitional `Decodable` forwarders for the item family.
//
// The domain types no longer know Plex's wire shape: each conformance below
// decodes the Plex DTO and maps it, stamping the server from
// `decoder.duskServerID` exactly as the old `init(from:)` did. They exist only
// because code outside the item family still decodes these types directly
// (the offline metadata cache, `DownloadManager`, play queues, extras,
// collections, watchlist, playlist entries, photo places, test fixtures).
// Once those call sites decode the DTOs and call `PlexItemMapper`, delete
// this file.

extension MediaItem: Decodable {
    init(from decoder: Decoder) throws {
        self = PlexItemMapper.map(try PlexItemDTO(from: decoder), serverID: decoder.duskServerID)
    }
}

extension MediaDetails: Decodable {
    init(from decoder: Decoder) throws {
        self = PlexItemMapper.map(try PlexMediaDetailsDTO(from: decoder), serverID: decoder.duskServerID)
    }
}

extension Episode: Decodable {
    init(from decoder: Decoder) throws {
        self = PlexItemMapper.map(try PlexEpisodeDTO(from: decoder), serverID: decoder.duskServerID)
    }
}

extension Season: Decodable {
    init(from decoder: Decoder) throws {
        self = PlexItemMapper.map(try PlexSeasonDTO(from: decoder), serverID: decoder.duskServerID)
    }
}

extension Library: Decodable {
    init(from decoder: Decoder) throws {
        self = PlexItemMapper.map(try PlexLibraryDTO(from: decoder), serverID: decoder.duskServerID)
    }
}

extension HomeRow: Decodable {
    init(from decoder: Decoder) throws {
        self = PlexItemMapper.map(try PlexHubDTO(from: decoder), serverID: decoder.duskServerID)
    }
}

extension Tag: Decodable {
    init(from decoder: Decoder) throws {
        self = PlexItemMapper.map(try PlexTagDTO(from: decoder))
    }
}
