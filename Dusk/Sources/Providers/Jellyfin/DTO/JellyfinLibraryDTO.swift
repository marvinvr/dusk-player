import Foundation

// Filters, counts, search, skip segments, playlists and Live TV.
// docs/jellyfin/02-jellyfin-api-mapping.md §3, §5, §7, §11, §15.

/// `GET /Items/Filters?parentId=` (legacy `QueryFiltersLegacy`).
struct JellyfinItemFiltersDTO: Decodable, Hashable, Sendable {
    let genres: [String]?
    let tags: [String]?
    let officialRatings: [String]?
    let years: [Int]?

    enum CodingKeys: String, CodingKey {
        case genres = "Genres"
        case tags = "Tags"
        case officialRatings = "OfficialRatings"
        case years = "Years"
    }
}

/// `GET /Items/Counts`.
struct JellyfinItemCountsDTO: Decodable, Hashable, Sendable {
    let movieCount: Int?
    let seriesCount: Int?
    let episodeCount: Int?
    let boxSetCount: Int?
    let itemCount: Int?
    let programCount: Int?
    let trailerCount: Int?

    enum CodingKeys: String, CodingKey {
        case movieCount = "MovieCount"
        case seriesCount = "SeriesCount"
        case episodeCount = "EpisodeCount"
        case boxSetCount = "BoxSetCount"
        case itemCount = "ItemCount"
        case programCount = "ProgramCount"
        case trailerCount = "TrailerCount"
    }
}

/// `GET /Search/Hints`. Note the envelope is `SearchHints`, not `Items`.
struct JellyfinSearchHintResultDTO: Decodable, Sendable {
    let searchHints: [JellyfinSearchHintDTO]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case searchHints = "SearchHints"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinSearchHintDTO: Decodable, Hashable, Sendable {
    let id: String
    let name: String?
    let type: JellyfinItemKind?
    let mediaType: JellyfinMediaType?
    let productionYear: Int?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let series: String?
    let runTimeTicks: JellyfinTicks?
    let primaryImageTag: String?
    let thumbImageTag: String?
    let thumbImageItemID: String?
    let backdropImageTag: String?
    let backdropImageItemID: String?
    let primaryImageAspectRatio: Double?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case mediaType = "MediaType"
        case productionYear = "ProductionYear"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case series = "Series"
        case runTimeTicks = "RunTimeTicks"
        case primaryImageTag = "PrimaryImageTag"
        case thumbImageTag = "ThumbImageTag"
        case thumbImageItemID = "ThumbImageItemId"
        case backdropImageTag = "BackdropImageTag"
        case backdropImageItemID = "BackdropImageItemId"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
    }
}

// MARK: - Skip markers

/// `GET /MediaSegments/{itemId}` entries. `Intro` → intro, `Outro` →
/// credits; an `Outro` that ends at the runtime is Plex's final credits.
struct JellyfinMediaSegmentDTO: Decodable, Hashable, Sendable {
    let id: String
    let itemID: String?
    let type: JellyfinMediaSegmentType
    let startTicks: JellyfinTicks
    let endTicks: JellyfinTicks

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case itemID = "ItemId"
        case type = "Type"
        case startTicks = "StartTicks"
        case endTicks = "EndTicks"
    }
}

// MARK: - Playlists

/// `POST /Playlists` body.
struct JellyfinCreatePlaylistDTO: Encodable, Sendable {
    var name: String
    var ids: [String]
    var userID: String?
    var mediaType: JellyfinMediaType = .video
    var isPublic = false

    init(name: String, ids: [String]) {
        self.name = name
        self.ids = ids
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case ids = "Ids"
        case userID = "UserId"
        case mediaType = "MediaType"
        case isPublic = "IsPublic"
    }
}

/// `POST /Playlists` answer.
struct JellyfinPlaylistCreationResultDTO: Decodable, Hashable, Sendable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

/// `POST /Playlists/{id}` body (rename).
struct JellyfinUpdatePlaylistDTO: Encodable, Sendable {
    var name: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }
}

/// `GET /Playlists/{id}`.
struct JellyfinPlaylistDTO: Decodable, Hashable, Sendable {
    let openAccess: Bool?
    let itemIDs: [String]
    let shares: [JellyfinPlaylistShareDTO]?

    enum CodingKeys: String, CodingKey {
        case openAccess = "OpenAccess"
        case itemIDs = "ItemIds"
        case shares = "Shares"
    }
}

struct JellyfinPlaylistShareDTO: Decodable, Hashable, Sendable {
    let userID: String?
    let canEdit: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case canEdit = "CanEdit"
    }
}

// MARK: - Live TV

/// `GET /LiveTv/Info`.
struct JellyfinLiveTVInfoDTO: Decodable, Hashable, Sendable {
    let isEnabled: Bool?
    let services: [JellyfinLiveTVServiceDTO]?
    let enabledUsers: [String]?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "IsEnabled"
        case services = "Services"
        case enabledUsers = "EnabledUsers"
    }
}

struct JellyfinLiveTVServiceDTO: Decodable, Hashable, Sendable {
    let name: String?
    let status: String?
    let isVisible: Bool?
    let tuners: [String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case status = "Status"
        case isVisible = "IsVisible"
        case tuners = "Tuners"
    }
}

/// `GET /LiveTv/GuideInfo`: the window the guide covers.
struct JellyfinGuideInfoDTO: Decodable, Hashable, Sendable {
    let startDate: JellyfinDate?
    let endDate: JellyfinDate?

    enum CodingKeys: String, CodingKey {
        case startDate = "StartDate"
        case endDate = "EndDate"
    }
}

/// A guide entry (`POST /LiveTv/Programs`, `CurrentProgram` on a channel).
/// Programs are `BaseItemDto`s; this keeps the guide fields.
struct JellyfinProgramDTO: Decodable, Hashable, Sendable {
    let id: String
    let name: String?
    let episodeTitle: String?
    let overview: String?
    let channelID: String?
    let startDate: JellyfinDate?
    let endDate: JellyfinDate?
    let isMovie: Bool?
    let isSeries: Bool?
    let isNews: Bool?
    let isSports: Bool?
    let isKids: Bool?
    let isLive: Bool?
    let isPremiere: Bool?
    let isRepeat: Bool?
    let imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case episodeTitle = "EpisodeTitle"
        case overview = "Overview"
        case channelID = "ChannelId"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case isMovie = "IsMovie"
        case isSeries = "IsSeries"
        case isNews = "IsNews"
        case isSports = "IsSports"
        case isKids = "IsKids"
        case isLive = "IsLive"
        case isPremiere = "IsPremiere"
        case isRepeat = "IsRepeat"
        case imageTags = "ImageTags"
    }
}

/// `POST /LiveTv/Programs` body.
struct JellyfinProgramsQueryDTO: Encodable, Sendable {
    var channelIDs: [String]
    var userID: String?
    var minEndDate: JellyfinDate?
    var maxStartDate: JellyfinDate?
    var startIndex: Int?
    var limit: Int?
    var fields: [JellyfinItemField]?
    var enableTotalRecordCount: Bool?

    init(channelIDs: [String], minEndDate: Date?, maxStartDate: Date?) {
        self.channelIDs = channelIDs
        self.minEndDate = minEndDate.map { JellyfinDate($0) }
        self.maxStartDate = maxStartDate.map { JellyfinDate($0) }
    }

    enum CodingKeys: String, CodingKey {
        case channelIDs = "ChannelIds"
        case userID = "UserId"
        case minEndDate = "MinEndDate"
        case maxStartDate = "MaxStartDate"
        case startIndex = "StartIndex"
        case limit = "Limit"
        case fields = "Fields"
        case enableTotalRecordCount = "EnableTotalRecordCount"
    }
}
