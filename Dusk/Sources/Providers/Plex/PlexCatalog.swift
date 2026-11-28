import Foundation

/// Plex's `CatalogProviding`: `/library/sections`, a section's `/all`,
/// `/firstCharacter`, `/filters`, `/collections` and `/prefs`, an item's
/// metadata, children, leaves and extras, `/library/people` and `/hubs/search`.
///
/// Every request goes to `serverID` through `transport`. The neutral sorts and
/// filters are mapped onto Plex's query here (`sortValue`, `queryFilters`).
/// The `raw…` methods take Plex's own sort strings and filter parameters for
/// the facade routes whose callers still pass them.
struct PlexCatalog: CatalogProviding {
    let serverID: String
    /// nil on the value `PlexServerProvider.catalog` hands out, which then
    /// throws `noServerConnected`; see `PlexServerTransport`.
    let transport: (any PlexServerTransport)?

    // MARK: - Libraries and browse

    func libraries() async throws -> [Library] {
        let sections: [PlexLibraryDTO] = try await directories(path: "/library/sections")
        return sections.map { PlexItemMapper.map($0, serverID: serverID) }
    }

    func items(
        libraryID: String,
        kind: LibraryKind?,
        start: Int,
        size: Int,
        sort: LibrarySortOption?,
        filter: LibraryFilter
    ) async throws -> [MediaItem] {
        try await rawItems(
            libraryID: libraryID,
            start: start,
            size: size,
            sort: sort.map(Self.sortValue),
            filters: Self.queryFilters(filter, kind: kind)
        )
    }

    func itemCount(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> Int {
        try await rawItemCount(libraryID: libraryID, filters: Self.queryFilters(filter, kind: kind))
    }

    /// `/library/sections/{id}/firstCharacter`: cheap even on a big library.
    func letterCounts(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> [LibraryLetterCount] {
        let rows: [PlexFirstCharacter] = try await directories(
            path: "/library/sections/\(libraryID)/firstCharacter",
            queryItems: Self.sortedQueryItems(Self.queryFilters(filter, kind: kind))
        )
        return rows.map { LibraryLetterCount(key: $0.key, size: $0.size) }
    }

    /// The fixed lists Plex's `/library/sections/{id}/sorts` offers per type.
    func sortFields(for kind: LibraryKind?) -> [LibrarySortField] {
        LibrarySortField.fields(for: kind)
    }

    /// The `offered` fields among the section's `/filters` rows.
    func filterFields(libraryID: String, includesCollection: Bool) async throws -> [LibraryFilterField] {
        Self.filterFields(from: try await rawFilters(libraryID: libraryID), includesCollection: includesCollection)
    }

    func filterChoices(for field: LibraryFilterField) async throws -> [LibraryFilterChoice] {
        guard case .values(let path) = field.kind else { return [] }
        return try await rawFilterValues(path: path).map(Self.filterChoice)
    }

    // MARK: - Collections

    /// The section's `collection` filter values: one per channel in a video
    /// library. Each `key` is a `LibraryFilter.collectionID`.
    func channelCollections(libraryID: String) async throws -> [MediaCollection] {
        let values: [LibraryFilterValue] = try await directories(path: "/library/sections/\(libraryID)/collection")
        return values.compactMap { MediaCollection(filterValue: $0, serverID: serverID) }
    }

    /// Manual and smart collections are both metadata items of type
    /// `collection`, listed per section.
    func collections(libraryID: String, start: Int, size: Int) async throws -> MediaItemPage {
        try await itemPage(path: "/library/sections/\(libraryID)/collections", start: start, size: size)
    }

    /// Expanded through `/children`, where the server resolves a smart
    /// collection's filter.
    func collectionItems(collectionID: String, start: Int, size: Int, sort: LibrarySortOption?) async throws -> MediaItemPage {
        try await rawCollectionItems(collectionID: collectionID, start: start, size: size, sort: sort.map(Self.sortValue))
    }

    func collection(itemID: String) async throws -> MediaItem? {
        let items: [PlexItemDTO] = try await metadata(path: "/library/metadata/\(itemID)")
        return items.first.map { PlexItemMapper.map($0, serverID: serverID) }
    }

    /// The section's `collectionMode` pref. Shared users may not be allowed to
    /// read a section's prefs; anything unreadable is Plex's default.
    func collectionMode(libraryID: String) async -> LibraryCollectionMode {
        let cacheKey = "\(serverID)|\(libraryID)"
        if let cached = PlexCollectionModeCache.modes[cacheKey] { return cached }
        guard let transport else { return .showItems }

        do {
            let data = try await transport.rawServerRequest(
                method: "GET",
                path: "/library/sections/\(libraryID)/prefs",
                queryItems: nil,
                timeoutInterval: nil,
                serverID: serverID
            )
            let settings = try transport.decodeJSON(SectionPrefsResponse.self, from: data, serverID: serverID)
                .MediaContainer.Setting ?? []
            let mode = settings.first { $0.id == "collectionMode" }
                .flatMap { $0.value.flatMap(Self.collectionMode(prefValue:)) } ?? .showItems
            PlexCollectionModeCache.modes[cacheKey] = mode
            return mode
        } catch {
            return .showItems
        }
    }

    // MARK: - Details and children

    /// `checkFiles=1` makes Plex stat the backing files so each `Part` carries
    /// accurate `accessible`/`exists` flags.
    func details(itemID: String, checkFiles: Bool) async throws -> MediaDetails {
        var queryItems = [
            URLQueryItem(name: "includeMarkers", value: "1"),
            URLQueryItem(name: "includeGuids", value: "1"),
        ]
        if checkFiles {
            queryItems.append(URLQueryItem(name: "checkFiles", value: "1"))
        }
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/library/metadata/\(itemID)",
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
        let response = try transport.decodeJSON(MetadataResponse<PlexMediaDetailsDTO>.self, from: data, serverID: serverID)
        guard let details = response.MediaContainer.Metadata?.first else {
            throw MediaServiceError.decodingError("No metadata found for ratingKey \(itemID)")
        }
        return PlexItemMapper.map(details, serverID: serverID)
    }

    func seasons(showID: String) async throws -> [Season] {
        let seasons: [PlexSeasonDTO] = try await metadata(path: "/library/metadata/\(showID)/children")
        return seasons.map { PlexItemMapper.map($0, serverID: serverID) }
    }

    func episodes(seasonID: String) async throws -> [Episode] {
        try await episodes(path: "/library/metadata/\(seasonID)/children")
    }

    func allEpisodes(showID: String) async throws -> [Episode] {
        try await episodes(path: "/library/metadata/\(showID)/allLeaves")
    }

    // MARK: - People, extras, search

    /// Person ids are per-server tag ids, exactly like rating keys.
    func person(id: String) async throws -> PersonDetails {
        let people: [PlexPersonDTO] = try await directories(path: "/library/people/\(id)")
        guard let person = people.first else {
            throw MediaServiceError.decodingError("No person found for id \(id)")
        }
        return PlexItemMapper.map(person)
    }

    func personMedia(id: String) async throws -> [MediaItem] {
        let rows: [PlexItemDTO] = try await metadata(
            path: "/library/people/\(id)/media",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")]
        )
        return rows.map { PlexItemMapper.map($0, serverID: serverID) }
    }

    /// Plex's "Local Files for Trailers and Extras". The listing is read twice
    /// from one payload: once as items, once for the extra-only fields.
    func extras(itemID: String) async throws -> [Extra] {
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/library/metadata/\(itemID)/extras",
            queryItems: nil,
            timeoutInterval: nil,
            serverID: serverID
        )
        let items = (try transport.decodeJSON(MetadataResponse<PlexItemDTO>.self, from: data, serverID: serverID)
            .MediaContainer.Metadata ?? [])
            .map { PlexItemMapper.map($0, serverID: serverID) }
        let fields = (try? transport.decodeJSON(MetadataResponse<PlexExtraFieldsDTO>.self, from: data, serverID: serverID))?
            .MediaContainer.Metadata ?? []
        return PlexUserContentMapper.extras(items: items, fields: fields)
    }

    /// `/hubs/search`: one hub per result type.
    func searchGroups(query: String) async throws -> [HomeRow] {
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/hubs/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "includeCollections", value: "0"),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            timeoutInterval: nil,
            serverID: serverID
        )
        let response = try transport.decodeJSON(PlexHubResponseDTO.self, from: data, serverID: serverID)
        return (response.MediaContainer.Hub ?? []).map { PlexItemMapper.map($0, serverID: serverID) }
    }

    // MARK: - Photos

    /// Plex search type ids: clip 12, photo 13, photo album 14.
    private static let photoAlbumType = "14"
    private static let photoMediaTypes = "13,12"

    /// Every query goes through the section's `/all` rather than an album's
    /// `/children`: `/children` mixes sub-albums in with the photos, so a
    /// date-sorted, paged walk over it would bury the albums on the last page.
    func photoPage(libraryID: String, query: PhotoQuery, start: Int, size: Int) async throws -> PhotoPage {
        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
        ]

        switch query {
        case .albums(let parent):
            queryItems.append(URLQueryItem(name: "type", value: Self.photoAlbumType))
            queryItems.append(URLQueryItem(name: "sort", value: "titleSort"))
            if let parent {
                queryItems.append(URLQueryItem(name: "parent", value: parent))
            }
        case .media(let parent):
            queryItems.append(URLQueryItem(name: "type", value: Self.photoMediaTypes))
            queryItems.append(URLQueryItem(name: "sort", value: "originallyAvailableAt,titleSort"))
            if let parent {
                queryItems.append(URLQueryItem(name: "parent", value: parent))
            }
        case .timeline:
            // Without `clusterZoomLevel=1` the type filter only reaches the
            // photos loose in the library root. It does not group anything:
            // the timeline is one flat, newest-first list.
            queryItems.append(URLQueryItem(name: "type", value: Self.photoMediaTypes))
            queryItems.append(URLQueryItem(name: "clusterZoomLevel", value: "1"))
            queryItems.append(URLQueryItem(name: "sort", value: "originallyAvailableAt:desc,addedAt:desc"))
        }

        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/library/sections/\(libraryID)/all",
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
        let response = try transport.decodeJSON(MetadataResponse<PlexPhotoItemDTO>.self, from: data, serverID: serverID)
        return PhotoPage(
            items: (response.MediaContainer.Metadata ?? [])
                .map { PlexUserContentMapper.photoItem($0, serverID: serverID) }
                .filter { $0.kind != nil },
            totalSize: response.MediaContainer.totalSize
        )
    }

    // MARK: - Plex-vocabulary reads

    /// A page of `/library/sections/{id}/all` in a Plex `sort` with Plex
    /// filter parameters, sent in key order.
    func rawItems(
        libraryID: String,
        start: Int,
        size: Int,
        sort: String?,
        filters: [String: String]
    ) async throws -> [MediaItem] {
        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
        ]

        if let sort, !sort.isEmpty {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }

        queryItems.append(contentsOf: Self.sortedQueryItems(filters))

        let items: [PlexItemDTO] = try await metadata(
            path: "/library/sections/\(libraryID)/all",
            queryItems: queryItems
        )
        return items.map { PlexItemMapper.map($0, serverID: serverID) }
    }

    /// The listing's size from a one-item page's `totalSize`.
    func rawItemCount(libraryID: String, filters: [String: String]) async throws -> Int {
        let queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "1"),
        ] + Self.sortedQueryItems(filters)

        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/library/sections/\(libraryID)/all",
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
        let response = try transport.decodeJSON(MetadataResponse<PlexItemDTO>.self, from: data, serverID: serverID)
        return response.MediaContainer.totalSize ?? response.MediaContainer.size ?? 0
    }

    /// The section's `/filters` rows.
    func rawFilters(libraryID: String) async throws -> [LibraryFilterEntry] {
        try await directories(path: "/library/sections/\(libraryID)/filters")
    }

    /// The values of one `/filters` row (`LibraryFilterEntry.key`).
    func rawFilterValues(path: String) async throws -> [LibraryFilterValue] {
        try await directories(path: path)
    }

    func rawCollectionItems(collectionID: String, start: Int, size: Int, sort: String?) async throws -> MediaItemPage {
        try await itemPage(
            path: "/library/metadata/\(collectionID)/children",
            start: start,
            size: size,
            extraQueryItems: sort.map { [URLQueryItem(name: "sort", value: $0)] } ?? []
        )
    }

    // MARK: - Requests

    private func routed() throws -> any PlexServerTransport {
        guard let transport else { throw MediaServiceError.noServerConnected }
        return transport
    }

    private func metadata<T: Decodable>(path: String, queryItems: [URLQueryItem]? = nil) async throws -> [T] {
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
        return try transport.decodeJSON(MetadataResponse<T>.self, from: data, serverID: serverID)
            .MediaContainer.Metadata ?? []
    }

    private func directories<T: Decodable>(path: String, queryItems: [URLQueryItem]? = nil) async throws -> [T] {
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
        return try transport.decodeJSON(DirectoryResponse<T>.self, from: data, serverID: serverID)
            .MediaContainer.Directory ?? []
    }

    private func episodes(path: String) async throws -> [Episode] {
        let episodes: [PlexEpisodeDTO] = try await metadata(path: path)
        return episodes.map { PlexItemMapper.map($0, serverID: serverID) }
    }

    private func itemPage(
        path: String,
        start: Int,
        size: Int,
        extraQueryItems: [URLQueryItem] = []
    ) async throws -> MediaItemPage {
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: path,
            queryItems: [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
            ] + extraQueryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
        let container = try transport.decodeJSON(MetadataResponse<PlexItemDTO>.self, from: data, serverID: serverID)
            .MediaContainer
        return MediaItemPage(
            items: (container.Metadata ?? []).map { PlexItemMapper.map($0, serverID: serverID) },
            totalSize: container.totalSize,
            start: start,
            requestedSize: size
        )
    }
}

// MARK: - Sorts and filters

extension PlexCatalog {
    /// Plex's `sort` key for a field.
    nonisolated static func sortKey(_ field: LibrarySortField) -> String {
        switch field {
        case .title: "titleSort"
        case .releaseDate: "originallyAvailableAt"
        case .year: "year"
        case .addedAt: "addedAt"
        case .lastEpisodeAdded: "episode.addedAt"
        case .userRating: "userRating"
        case .criticRating: "rating"
        case .audienceRating: "audienceRating"
        case .duration: "duration"
        case .lastViewed: "lastViewedAt"
        case .random: "random"
        }
    }

    /// Plex's `sort` value: the key, `:desc` when descending.
    nonisolated static func sortValue(_ sort: LibrarySortOption) -> String {
        guard sort.field.hasDirection else { return sortKey(sort.field) }
        return sort.isDescending ? "\(sortKey(sort.field)):desc" : sortKey(sort.field)
    }

    /// Plex's parameters for a watch state. Movies and videos filter the item
    /// itself (`unwatched`, so a movie in progress still counts as
    /// unwatched); shows filter on their episodes (`unwatchedLeaves`), so a
    /// show is "watched" once every episode is. Plex has no in-progress filter
    /// for show sections. These are what Plex's own clients send.
    nonisolated static func watchStatusParameter(_ status: LibraryWatchStatus, kind: LibraryKind?) -> (name: String, value: String)? {
        let unwatchedName = kind == .show ? "unwatchedLeaves" : "unwatched"
        switch status {
        case .all: return nil
        case .unwatched: return (unwatchedName, "1")
        case .watched: return (unwatchedName, "0")
        case .inProgress: return kind == .show ? nil : ("inProgress", "1")
        }
    }

    /// A neutral filter as Plex's query parameters. A picked field value
    /// wins over the collection or genre of the same name, as it always has.
    nonisolated static func queryFilters(_ filter: LibraryFilter, kind: LibraryKind?) -> [String: String] {
        var filters: [String: String] = [:]
        if let collectionID = filter.collectionID {
            filters["collection"] = collectionID
        }
        if let genre = filter.genre {
            filters["genre"] = genre
        }
        if let status = watchStatusParameter(filter.watchStatus, kind: kind) {
            filters[status.name] = status.value
        }
        for (parameter, value) in filter.choices {
            filters[parameter] = value
        }
        for parameter in filter.toggles {
            filters[parameter] = "1"
        }
        if filter.foldsCollections {
            filters["includeCollections"] = "1"
        }
        return filters
    }

    nonisolated static func sortedQueryItems(_ filters: [String: String]) -> [URLQueryItem] {
        filters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    /// Which of Plex's section filters the sheet offers, with Dusk's titles,
    /// in the sheet's order.
    nonisolated static let offeredFilters: [(parameter: String, title: String)] = [
        ("decade", "Decade"),
        ("year", "Year"),
        ("contentRating", "Content Rating"),
        ("resolution", "Resolution"),
        ("hdr", "HDR"),
        ("dovi", "Dolby Vision"),
        ("audioLanguage", "Audio Language"),
        ("studio", "Studio"),
        ("network", "Network"),
        ("collection", "Collection"),
        ("director", "Director"),
        ("actor", "Actor"),
    ]

    /// The offered fields among a section's `/filters` rows. A `boolean` row
    /// is a toggle (`hdr=1`); any other lists its values at its `key`.
    nonisolated static func filterFields(from filters: [LibraryFilterEntry], includesCollection: Bool) -> [LibraryFilterField] {
        let byName = Dictionary(filters.map { ($0.filter, $0) }, uniquingKeysWith: { first, _ in first })
        return offeredFilters.compactMap { offered in
            guard includesCollection || offered.parameter != "collection",
                  let filter = byName[offered.parameter] else { return nil }
            let kind: LibraryFilterField.Kind = filter.filterType == "boolean" ? .toggle : .values(source: filter.key)
            return LibraryFilterField(parameter: offered.parameter, title: offered.title, kind: kind)
        }
    }

    /// Plex percent-encodes some keys (`Not%20Rated`): the choice keeps the
    /// decoded value, which is encoded once when the query is built.
    nonisolated static func filterChoice(_ value: LibraryFilterValue) -> LibraryFilterChoice {
        LibraryFilterChoice(value: value.key.removingPercentEncoding ?? value.key, title: value.title)
    }

    /// The section prefs' `collectionMode` value.
    nonisolated static func collectionMode(prefValue: String) -> LibraryCollectionMode? {
        switch prefValue {
        case "0": .disabled
        case "1": .hideItems
        case "2": .showItems
        default: nil
        }
    }
}

extension LibrarySortOption {
    /// Plex's `sort` value. For the callers outside the catalog that still
    /// send their own Plex request (collection pages).
    var plexValue: String { PlexCatalog.sortValue(self) }
}

/// Section settings rarely change while the app runs; one read per section
/// per launch is enough.
@MainActor
private enum PlexCollectionModeCache {
    static var modes: [String: LibraryCollectionMode] = [:]
}

private struct SectionPrefsResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Setting: [Setting]?
    }

    struct Setting: Decodable {
        let id: String
        let value: String?

        enum CodingKeys: String, CodingKey {
            case id, value
        }

        /// Plex types each setting's value by the setting (`int`, `bool`,
        /// `text`), so it is read as whatever it is and kept as text.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            if let int = try? container.decodeIfPresent(Int.self, forKey: .value) {
                value = String(int)
            } else if let bool = try? container.decodeIfPresent(Bool.self, forKey: .value) {
                value = bool ? "1" : "0"
            } else {
                value = try? container.decodeIfPresent(String.self, forKey: .value)
            }
        }
    }
}

extension PlexServerProvider {
    /// Sends through the account's routed send (`PlexServerRouter`).
    var catalog: any CatalogProviding { plexCatalog }
    /// The catalog with the Plex-only members the facade's raw routes use.
    var plexCatalog: PlexCatalog { PlexCatalog(serverID: descriptor.id, transport: router) }
}
