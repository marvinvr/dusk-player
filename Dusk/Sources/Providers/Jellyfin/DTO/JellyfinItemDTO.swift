import Foundation

// `BaseItemDto` and its parts: every item-shaped response (libraries, browse,
// details, seasons, episodes, people, photos, playlists, Live TV channels).
// docs/jellyfin/02-jellyfin-api-mapping.md §2 – §6, §11 – §13.
//
// List responses are slim unless `fields=` asks for more, so everything except
// `Id` is optional. Absent beats null on this server: an unplayed item's
// `UserData` has no `PlayedPercentage` or `LastPlayedDate` at all.

struct JellyfinItemDTO: Decodable, Sendable {
    let id: String
    let name: String?
    let originalTitle: String?
    let sortName: String?
    let serverID: String?
    let type: JellyfinItemKind?
    let mediaType: JellyfinMediaType?
    let collectionType: JellyfinCollectionType?
    let isFolder: Bool?
    let parentID: String?
    let path: String?
    let etag: String?
    let locationType: JellyfinLocationType?
    let extraType: JellyfinExtraType?

    // Text and classification
    let overview: String?
    let taglines: [String]?
    let genres: [String]?
    let genreItems: [JellyfinNameIDDTO]?
    let studios: [JellyfinNameIDDTO]?
    let tags: [String]?
    let productionLocations: [String]?
    let officialRating: String?
    /// TMDB-style 0–10; no source field (02 §6).
    let communityRating: Double?
    /// 0–100 when a provider fills it.
    let criticRating: Double?
    let providerIDs: [String: String]?
    let externalURLs: [JellyfinExternalURLDTO]?
    let remoteTrailers: [JellyfinRemoteTrailerDTO]?
    let localTrailerCount: Int?
    let specialFeatureCount: Int?
    let people: [JellyfinPersonDTO]?
    let originalLanguage: String?

    // Time
    let runTimeTicks: JellyfinTicks?
    let cumulativeRunTimeTicks: JellyfinTicks?
    let productionYear: Int?
    /// Local midnight stored as UTC for episodes and people (`…T23:00:00Z` of
    /// the previous day); the mapper rounds to the nearest day.
    let premiereDate: JellyfinDate?
    let endDate: JellyfinDate?
    let dateCreated: JellyfinDate?
    let dateLastMediaAdded: JellyfinDate?
    let status: String?
    let airDays: [String]?

    // Hierarchy (seasons, episodes)
    let indexNumber: Int?
    let indexNumberEnd: Int?
    let parentIndexNumber: Int?
    let seriesID: String?
    let seriesName: String?
    let seriesStudio: String?
    let seasonID: String?
    let seasonName: String?
    let childCount: Int?
    let recursiveItemCount: Int?
    let playlistItemID: String?

    // Artwork. Tags are cache-busters, not validators: always put them in the
    // image URL (03 §10.4).
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let imageBlurHashes: [String: [String: String]]?
    let primaryImageAspectRatio: Double?
    let seriesPrimaryImageTag: String?
    let parentPrimaryImageItemID: String?
    let parentPrimaryImageTag: String?
    let parentBackdropItemID: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemID: String?
    let parentLogoImageTag: String?
    let parentThumbItemID: String?
    let parentThumbImageTag: String?

    // Media
    let container: String?
    let videoType: String?
    let hasSubtitles: Bool?
    let isHD: Bool?
    let width: Int?
    let height: Int?
    let mediaSourceCount: Int?
    let mediaSources: [JellyfinMediaSourceDTO]?
    /// Streams of the primary source, repeated at item level on details.
    let mediaStreams: [JellyfinMediaStreamDTO]?
    let chapters: [JellyfinChapterDTO]?
    /// `Trickplay[mediaSourceId][width]` (`fields=Trickplay`).
    let trickplay: [String: [String: JellyfinTrickplayInfoDTO]]?
    let canDownload: Bool?
    let canDelete: Bool?

    // Photos (EXIF; null on images without it)
    let imageOrientation: String?
    let cameraMake: String?
    let cameraModel: String?
    let latitude: Double?
    let longitude: Double?

    // Live TV
    let channelID: String?
    let channelNumber: String?
    let number: String?
    let currentProgram: JellyfinProgramDTO?

    let userData: JellyfinUserDataDTO?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case originalTitle = "OriginalTitle"
        case sortName = "SortName"
        case serverID = "ServerId"
        case type = "Type"
        case mediaType = "MediaType"
        case collectionType = "CollectionType"
        case isFolder = "IsFolder"
        case parentID = "ParentId"
        case path = "Path"
        case etag = "Etag"
        case locationType = "LocationType"
        case extraType = "ExtraType"
        case overview = "Overview"
        case taglines = "Taglines"
        case genres = "Genres"
        case genreItems = "GenreItems"
        case studios = "Studios"
        case tags = "Tags"
        case productionLocations = "ProductionLocations"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case providerIDs = "ProviderIds"
        case externalURLs = "ExternalUrls"
        case remoteTrailers = "RemoteTrailers"
        case localTrailerCount = "LocalTrailerCount"
        case specialFeatureCount = "SpecialFeatureCount"
        case people = "People"
        case originalLanguage = "OriginalLanguage"
        case runTimeTicks = "RunTimeTicks"
        case cumulativeRunTimeTicks = "CumulativeRunTimeTicks"
        case productionYear = "ProductionYear"
        case premiereDate = "PremiereDate"
        case endDate = "EndDate"
        case dateCreated = "DateCreated"
        case dateLastMediaAdded = "DateLastMediaAdded"
        case status = "Status"
        case airDays = "AirDays"
        case indexNumber = "IndexNumber"
        case indexNumberEnd = "IndexNumberEnd"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesID = "SeriesId"
        case seriesName = "SeriesName"
        case seriesStudio = "SeriesStudio"
        case seasonID = "SeasonId"
        case seasonName = "SeasonName"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case playlistItemID = "PlaylistItemId"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case imageBlurHashes = "ImageBlurHashes"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case parentPrimaryImageItemID = "ParentPrimaryImageItemId"
        case parentPrimaryImageTag = "ParentPrimaryImageTag"
        case parentBackdropItemID = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemID = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case parentThumbItemID = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case container = "Container"
        case videoType = "VideoType"
        case hasSubtitles = "HasSubtitles"
        case isHD = "IsHD"
        case width = "Width"
        case height = "Height"
        case mediaSourceCount = "MediaSourceCount"
        case mediaSources = "MediaSources"
        case mediaStreams = "MediaStreams"
        case chapters = "Chapters"
        case trickplay = "Trickplay"
        case canDownload = "CanDownload"
        case canDelete = "CanDelete"
        case imageOrientation = "ImageOrientation"
        case cameraMake = "CameraMake"
        case cameraModel = "CameraModel"
        case latitude = "Latitude"
        case longitude = "Longitude"
        case channelID = "ChannelId"
        case channelNumber = "ChannelNumber"
        case number = "Number"
        case currentProgram = "CurrentProgram"
        case userData = "UserData"
    }

    /// `ImageTags[type]`.
    func imageTag(_ type: JellyfinImageType) -> String? {
        imageTags?.first(where: { JellyfinImageType(rawValue: $0.key).matches(type) })?.value
    }

    /// `ProviderIds` lookup ignoring key case (`Tmdb`, `Imdb`, `Tvdb`,
    /// `TmdbCollection`).
    func providerID(_ name: String) -> String? {
        guard let value = providerIDs?.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value,
              !value.isEmpty else { return nil }
        return value
    }
}

/// `UserItemDataDto`. Keys are absent when zero or never set.
/// Also the answer of `GET /UserItems/{id}/UserData` and of the played calls.
struct JellyfinUserDataDTO: Decodable, Hashable, Sendable {
    let playbackPositionTicks: JellyfinTicks?
    let playCount: Int?
    let isFavorite: Bool?
    let played: Bool?
    let playedPercentage: Double?
    let lastPlayedDate: JellyfinDate?
    let unplayedItemCount: Int?
    let likes: Bool?
    let rating: Double?
    let key: String?
    let itemID: String?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case playedPercentage = "PlayedPercentage"
        case lastPlayedDate = "LastPlayedDate"
        case unplayedItemCount = "UnplayedItemCount"
        case likes = "Likes"
        case rating = "Rating"
        case key = "Key"
        case itemID = "ItemId"
    }
}

/// `POST /UserItems/{id}/UserData` body: set position / clear resume,
/// offline replay. Only the fields that are set are sent.
struct JellyfinUserDataUpdateDTO: Encodable, Sendable {
    var playbackPositionTicks: JellyfinTicks?
    var played: Bool?
    var playCount: Int?
    var isFavorite: Bool?
    var lastPlayedDate: JellyfinDate?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case lastPlayedDate = "LastPlayedDate"
    }
}

/// `{Name, Id}` (genres, studios).
struct JellyfinNameIDDTO: Decodable, Hashable, Sendable {
    let name: String?
    let id: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
    }
}

/// `BaseItemPerson`: cast and crew in `People[]`, split on `type`.
struct JellyfinPersonDTO: Decodable, Hashable, Sendable {
    let id: String
    let name: String?
    let role: String?
    let type: JellyfinPersonKind?
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

/// `ChapterInfo`. No end time: the next chapter's start or the runtime.
struct JellyfinChapterDTO: Decodable, Hashable, Sendable {
    let startPositionTicks: JellyfinTicks
    let name: String?
    let imageTag: String?
    let imageDateModified: JellyfinDate?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
        case imageDateModified = "ImageDateModified"
    }
}

/// `MediaUrl` in `RemoteTrailers[]` (mostly YouTube).
struct JellyfinRemoteTrailerDTO: Decodable, Hashable, Sendable {
    let url: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case url = "Url"
        case name = "Name"
    }
}

struct JellyfinExternalURLDTO: Decodable, Hashable, Sendable {
    let name: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case url = "Url"
    }
}

/// One trickplay rendition. `interval` is **milliseconds**, not ticks.
/// Thumbnail `i` is on sheet `i / (tileWidth × tileHeight)`.
struct JellyfinTrickplayInfoDTO: Decodable, Hashable, Sendable {
    let width: Int
    let height: Int
    let tileWidth: Int
    let tileHeight: Int
    let thumbnailCount: Int
    let interval: Int
    let bandwidth: Int?

    enum CodingKeys: String, CodingKey {
        case width = "Width"
        case height = "Height"
        case tileWidth = "TileWidth"
        case tileHeight = "TileHeight"
        case thumbnailCount = "ThumbnailCount"
        case interval = "Interval"
        case bandwidth = "Bandwidth"
    }
}

/// `GET /Items/{id}/Images` entries.
struct JellyfinImageInfoDTO: Decodable, Hashable, Sendable {
    let imageType: JellyfinImageType
    let imageIndex: Int?
    let imageTag: String?
    let width: Int?
    let height: Int?
    let size: Int64?
    let blurHash: String?

    enum CodingKeys: String, CodingKey {
        case imageType = "ImageType"
        case imageIndex = "ImageIndex"
        case imageTag = "ImageTag"
        case width = "Width"
        case height = "Height"
        case size = "Size"
        case blurHash = "BlurHash"
    }
}
