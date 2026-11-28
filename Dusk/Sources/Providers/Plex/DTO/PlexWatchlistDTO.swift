import Foundation

/// One title of plex.tv's Discover Watchlist (`/library/sections/watchlist/all`,
/// `/library/metadata/{id}`). Mapped to `WatchlistEntry` by
/// `PlexUserContentMapper`.
struct PlexWatchlistEntryDTO: Decodable, Sendable {
    let itemID: String
    let guid: String
    let type: MediaKind
    let title: String
    let year: Int?
    let thumb: String?
    let art: String?
    let summary: String?
    let contentRating: String?
    let duration: Int?
    let childCount: Int?
    /// Only the metadata call sends the `Guid` array.
    let guids: [String]

    enum CodingKeys: String, CodingKey {
        case itemID = "ratingKey", guid, type, title, year, thumb, art, summary, contentRating, duration, childCount
        case guids = "Guid"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(String.self, forKey: .itemID)
        guid = try container.decode(String.self, forKey: .guid)
        type = try container.decode(MediaKind.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        contentRating = try container.decodeIfPresent(String.self, forKey: .contentRating)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        childCount = try container.decodeIfPresent(Int.self, forKey: .childCount)
        guids = (try? container.decodeIfPresent([WatchlistGuid].self, forKey: .guids))?.map(\.id) ?? []
    }
}

/// One `Guid` entry (`tmdb://603`).
private struct WatchlistGuid: Decodable {
    let id: String
}

/// `GET /library/metadata/{itemID}/availabilities` on Discover.
struct PlexWatchlistAvailabilityDTO: Decodable, Sendable {
    let title: String?
    let offerType: String?
}
