import Foundation

/// `fields=` values: list responses are slim unless asked (02 §0).
struct JellyfinItemField: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let overview: Self = "Overview"
    static let genres: Self = "Genres"
    static let people: Self = "People"
    static let studios: Self = "Studios"
    static let tags: Self = "Tags"
    static let taglines: Self = "Taglines"
    static let mediaSources: Self = "MediaSources"
    static let mediaStreams: Self = "MediaStreams"
    static let mediaSourceCount: Self = "MediaSourceCount"
    static let chapters: Self = "Chapters"
    static let trickplay: Self = "Trickplay"
    static let providerIDs: Self = "ProviderIds"
    static let childCount: Self = "ChildCount"
    static let recursiveItemCount: Self = "RecursiveItemCount"
    static let dateCreated: Self = "DateCreated"
    static let dateLastMediaAdded: Self = "DateLastMediaAdded"
    static let path: Self = "Path"
    static let primaryImageAspectRatio: Self = "PrimaryImageAspectRatio"
    static let width: Self = "Width"
    static let height: Self = "Height"
    static let remoteTrailers: Self = "RemoteTrailers"
    static let externalURLs: Self = "ExternalUrls"
    static let productionLocations: Self = "ProductionLocations"
    static let originalTitle: Self = "OriginalTitle"
    static let sortName: Self = "SortName"
    static let canDownload: Self = "CanDownload"
    static let specialFeatureCount: Self = "SpecialFeatureCount"
}

/// `sortBy=` values (`ItemSortBy`).
struct JellyfinSortKey: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let sortName: Self = "SortName"
    static let name: Self = "Name"
    static let premiereDate: Self = "PremiereDate"
    static let productionYear: Self = "ProductionYear"
    static let dateCreated: Self = "DateCreated"
    static let dateLastContentAdded: Self = "DateLastContentAdded"
    static let datePlayed: Self = "DatePlayed"
    static let playCount: Self = "PlayCount"
    static let communityRating: Self = "CommunityRating"
    static let criticRating: Self = "CriticRating"
    static let officialRating: Self = "OfficialRating"
    static let runtime: Self = "Runtime"
    static let random: Self = "Random"
    static let indexNumber: Self = "IndexNumber"
    static let parentIndexNumber: Self = "ParentIndexNumber"
}

/// `filters=` values (`ItemFilter`).
struct JellyfinItemFilter: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let isPlayed: Self = "IsPlayed"
    static let isUnplayed: Self = "IsUnplayed"
    static let isResumable: Self = "IsResumable"
    static let isFavorite: Self = "IsFavorite"
    static let isFolder: Self = "IsFolder"
    static let isNotFolder: Self = "IsNotFolder"
    static let likes: Self = "Likes"
    static let dislikes: Self = "Dislikes"
}

enum JellyfinSortOrder: String, Sendable {
    case ascending = "Ascending"
    case descending = "Descending"
}

/// Parameters of `GET /Items` (browse, grids, collections, photos, search,
/// counts). Typed so a misspelt parameter, which the server would silently
/// ignore, cannot be written.
struct JellyfinItemQuery: Hashable, Sendable {
    var parentID: String?
    var ids: [String] = []
    var recursive: Bool?
    var includeItemTypes: [JellyfinItemKind] = []
    var excludeItemTypes: [JellyfinItemKind] = []
    var mediaTypes: [JellyfinMediaType] = []
    var fields: [JellyfinItemField] = []
    var sortBy: [JellyfinSortKey] = []
    var sortOrder: JellyfinSortOrder?
    var startIndex: Int?
    /// `0` returns only `TotalRecordCount`.
    var limit: Int?
    var enableTotalRecordCount: Bool?
    var filters: [JellyfinItemFilter] = []
    var isPlayed: Bool?
    var isFavorite: Bool?
    var searchTerm: String?
    var genres: [String] = []
    var genreIDs: [String] = []
    var years: [Int] = []
    var officialRatings: [String] = []
    var studios: [String] = []
    var studioIDs: [String] = []
    var tags: [String] = []
    var person: String?
    var personIDs: [String] = []
    var personTypes: [JellyfinPersonKind] = []
    /// The A–Z building blocks; all compare against the sort name.
    var nameStartsWith: String?
    var nameStartsWithOrGreater: String?
    var nameLessThan: String?
    var is4K: Bool?
    var isHD: Bool?
    var hasSubtitles: Bool?
    var hasTmdbID: Bool?
    var hasImdbID: Bool?
    var hasTvdbID: Bool?
    var collapseBoxSetItems: Bool?
    var enableUserData: Bool?
    var enableImages: Bool?
    var imageTypeLimit: Int?

    init() {}

    var queryItems: [URLQueryItem] {
        var query = JellyfinQuery()
        query.add("parentId", parentID)
        query.add("ids", list: ids)
        query.add("recursive", recursive)
        query.add("includeItemTypes", list: includeItemTypes)
        query.add("excludeItemTypes", list: excludeItemTypes)
        query.add("mediaTypes", list: mediaTypes)
        query.add("fields", list: fields)
        query.add("sortBy", list: sortBy)
        query.add("sortOrder", sortOrder?.rawValue)
        query.add("startIndex", startIndex)
        query.add("limit", limit)
        query.add("enableTotalRecordCount", enableTotalRecordCount)
        query.add("filters", list: filters)
        query.add("isPlayed", isPlayed)
        query.add("isFavorite", isFavorite)
        query.add("searchTerm", searchTerm)
        // Names may contain commas, so name lists are pipe-separated.
        query.add("genres", list: genres, separator: "|")
        query.add("genreIds", list: genreIDs, separator: "|")
        query.add("years", list: years.map(String.init))
        query.add("officialRatings", list: officialRatings, separator: "|")
        query.add("studios", list: studios, separator: "|")
        query.add("studioIds", list: studioIDs, separator: "|")
        query.add("tags", list: tags, separator: "|")
        query.add("person", person)
        query.add("personIds", list: personIDs, separator: "|")
        query.add("personTypes", list: personTypes)
        query.add("nameStartsWith", nameStartsWith)
        query.add("nameStartsWithOrGreater", nameStartsWithOrGreater)
        query.add("nameLessThan", nameLessThan)
        query.add("is4K", is4K)
        query.add("isHD", isHD)
        query.add("hasSubtitles", hasSubtitles)
        query.add("hasTmdbId", hasTmdbID)
        query.add("hasImdbId", hasImdbID)
        query.add("hasTvdbId", hasTvdbID)
        query.add("collapseBoxSetItems", collapseBoxSetItems)
        query.add("enableUserData", enableUserData)
        query.add("enableImages", enableImages)
        query.add("imageTypeLimit", imageTypeLimit)
        return query.items
    }

    /// Checks that a `200` answer is the result this query asked for. The
    /// server ignores what it does not understand and answers with a default
    /// list, so a dropped filter shows up here instead of as wrong rows.
    func validate(_ result: JellyfinQueryResult<JellyfinItemDTO>) throws {
        try JellyfinItemQuery.validate(
            result.items,
            includeItemTypes: includeItemTypes,
            excludeItemTypes: excludeItemTypes,
            limit: limit,
            ids: ids,
            isPlayed: isPlayed,
            isFavorite: isFavorite,
            expectsUserData: enableUserData != false
        )
    }

    static func validate(
        _ items: [JellyfinItemDTO],
        includeItemTypes: [JellyfinItemKind] = [],
        excludeItemTypes: [JellyfinItemKind] = [],
        limit: Int? = nil,
        ids: [String] = [],
        isPlayed: Bool? = nil,
        isFavorite: Bool? = nil,
        expectsUserData: Bool = true
    ) throws {
        if let limit, items.count > limit {
            throw JellyfinError.unexpectedResponse("\(items.count) items for limit \(limit)")
        }
        if !includeItemTypes.isEmpty,
           let stray = items.first(where: { item in !includeItemTypes.contains { item.type?.matches($0) == true } }) {
            throw JellyfinError.unexpectedResponse("item of type \(stray.type?.rawValue ?? "nil") outside includeItemTypes")
        }
        if let stray = items.first(where: { item in excludeItemTypes.contains { item.type?.matches($0) == true } }) {
            throw JellyfinError.unexpectedResponse("item of excluded type \(stray.type?.rawValue ?? "nil")")
        }
        if !ids.isEmpty {
            let wanted = Set(ids.map(JellyfinID.normalized))
            if items.contains(where: { !wanted.contains(JellyfinID.normalized($0.id)) }) {
                throw JellyfinError.unexpectedResponse("item outside the requested ids")
            }
        }
        if expectsUserData, items.contains(where: { $0.userData == nil }) {
            throw JellyfinError.unexpectedResponse("item without UserData; userId was not applied")
        }
        if let isPlayed, items.contains(where: { $0.userData.map { ($0.played ?? false) != isPlayed } ?? false }) {
            throw JellyfinError.unexpectedResponse("isPlayed=\(isPlayed) not applied")
        }
        if let isFavorite, items.contains(where: { $0.userData.map { ($0.isFavorite ?? false) != isFavorite } ?? false }) {
            throw JellyfinError.unexpectedResponse("isFavorite=\(isFavorite) not applied")
        }
    }
}
