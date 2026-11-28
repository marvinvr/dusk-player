import Foundation

/// One title on the account's Plex Watchlist, as plex.tv's Discover provider
/// (`discover.provider.plex.tv`) returns it. Account-level, not on any server:
/// `itemID` is Plex's global hex id, the same one that ends `guid`
/// (`plex://movie/<itemID>`), and the artwork URLs are absolute CDN links.
///
/// The list payload carries no `Guid` array; only the metadata call
/// (`PlexService.getWatchlistMetadata`) does, which is where the TMDB id for
/// Seerr comes from.
struct WatchlistEntry: Decodable, Hashable, Sendable, Identifiable {
    let itemID: String
    let guid: String
    let type: MediaKind
    let title: String
    let year: Int?
    let thumb: String?
    let art: String?
    let summary: String?
    let contentRating: String?
    /// Milliseconds.
    let duration: Int?
    let childCount: Int?
    let guids: [PlexGuid]

    var id: String { guid }

    enum CodingKeys: String, CodingKey {
        case itemID = "ratingKey", guid, type, title, year, thumb, art, summary, contentRating, duration, childCount
        case guids = "Guid"
    }

    init(
        itemID: String,
        guid: String,
        type: MediaKind,
        title: String,
        year: Int? = nil,
        thumb: String? = nil,
        art: String? = nil,
        summary: String? = nil,
        contentRating: String? = nil,
        duration: Int? = nil,
        childCount: Int? = nil,
        guids: [PlexGuid] = []
    ) {
        self.itemID = itemID
        self.guid = guid
        self.type = type
        self.title = title
        self.year = year
        self.thumb = thumb
        self.art = art
        self.summary = summary
        self.contentRating = contentRating
        self.duration = duration
        self.childCount = childCount
        self.guids = guids
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
        guids = (try? container.decodeIfPresent([PlexGuid].self, forKey: .guids)) ?? []
    }

    /// Built from a server item being added, so the Home row can show it
    /// before plex.tv's list is read again.
    init?(item: MediaItem) {
        guard let itemID = WatchlistEntry.discoverRatingKey(guid: item.guid, type: item.type),
              let guid = item.guid else { return nil }
        self.init(itemID: itemID, guid: guid, type: item.type, title: item.title, year: item.year)
    }

    init?(details: MediaDetails) {
        guard let itemID = WatchlistEntry.discoverRatingKey(guid: details.guid, type: details.type),
              let guid = details.guid else { return nil }
        self.init(
            itemID: itemID,
            guid: guid,
            type: details.type,
            title: details.title,
            year: details.year,
            summary: details.summary
        )
    }

    var tmdbID: Int? {
        externalIDs.values(for: "tmdb").lazy.compactMap(Int.init).first
    }

    func posterURL(width: Int) -> URL? {
        Self.artworkURL(thumb, width: width)
    }

    /// Plex hands out absolute artwork links. TMDB's are the `original`
    /// size, often several MB, so they are asked for at a size that fits;
    /// Plex's own CDN images are used as they are.
    static func artworkURL(_ string: String?, width: Int) -> URL? {
        guard let string = string?.nilIfEmpty, var url = URL(string: string) else { return nil }
        if url.host() == "image.tmdb.org", string.contains("/t/p/original/") {
            let size = switch width {
            case ...342: "w342"
            case ...500: "w500"
            case ...780: "w780"
            default: "w1280"
            }
            url = URL(string: string.replacingOccurrences(of: "/t/p/original/", with: "/t/p/\(size)/")) ?? url
        }
        return url
    }

    var seerrMediaType: SeerrMediaType {
        type == .show ? .tv : .movie
    }

    /// Plex's Watchlist only takes movies and shows, and only through their
    /// global `plex://` id. Legacy-agent items (`com.plexapp.agents.*`,
    /// `local://`) have none, so they get no bookmark rather than a guess.
    static func discoverRatingKey(guid: String?, type: MediaKind) -> String? {
        guard let guid else { return nil }
        let prefix: String
        switch type {
        case .movie: prefix = "plex://movie/"
        case .show: prefix = "plex://show/"
        default: return nil
        }
        guard guid.hasPrefix(prefix) else { return nil }
        return String(guid.dropFirst(prefix.count)).nilIfEmpty
    }
}

/// `GET /library/metadata/{itemID}/availabilities`: where a title streams.
/// Region-dependent; Dusk shows the service names only, no deep links.
struct PlexWatchlistAvailability: Decodable, Hashable, Sendable {
    let title: String?
    let offerType: String?

    /// Services that play it as part of something the user may already have
    /// (subscription, free, with ads), as opposed to buying or renting.
    var isIncluded: Bool {
        switch offerType {
        case "subscription", "free", "ads", "avod": true
        default: false
        }
    }
}

/// One row of Plex's own Home layout (`experience.homeSettings.hubs` in Plex
/// Web's per-product settings). Only what placing the Watchlist needs.
struct PlexHomeHubSetting: Hashable, Sendable {
    let hubIdentifier: String
    let machineIdentifier: String?
    let isHidden: Bool

    static let watchlistIdentifier = "home.watchlist"

    var isWatchlist: Bool { hubIdentifier == Self.watchlistIdentifier }

    init(hubIdentifier: String, machineIdentifier: String? = nil, isHidden: Bool = false) {
        self.hubIdentifier = hubIdentifier
        self.machineIdentifier = machineIdentifier
        self.isHidden = isHidden
    }

    init?(raw: DuskJSONValue) {
        guard let identifier = raw["hubIdentifier"]?.stringValue?.nilIfEmpty else { return nil }
        self.init(
            hubIdentifier: identifier,
            machineIdentifier: raw["server"]?["machineIdentifier"]?.stringValue?.nilIfEmpty,
            isHidden: raw["isHidden"]?.boolValue ?? false
        )
    }
}
