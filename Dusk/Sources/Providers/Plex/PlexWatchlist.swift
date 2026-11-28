import Foundation

/// Plex's `WatchlistProviding`: the account's Plex Watchlist on plex.tv's
/// Discover provider, and Plex Web's Home layout for placing its row.
///
/// Undocumented but stable (every Plex client, Overseerr/Seerr and Kometa use
/// it). Verified against a real account on 2026-10-25:
/// - `GET /library/sections/watchlist/all?sort=watchlistedAt:desc`, paged with
///   `X-Plex-Container-Start/Size`, `totalSize` in the container;
/// - `PUT /actions/addToWatchlist?itemID=` / `removeFromWatchlist`, both
///   idempotent (200 with an empty container either way);
/// - `GET /library/metadata/{itemID}` carries the `Guid` array (tmdb/imdb);
/// - `GET /library/metadata/{itemID}/availabilities` lists services.
///
/// The itemID is the hex id that ends a modern server item's `plex://`
/// guid, so a server item needs no lookup to be added.
struct PlexWatchlist: WatchlistProviding {
    let client: PlexClient
    /// nil only on the value `PlexAccountProvider.watchlist` hands out, which
    /// then refuses every call; see `PlexAccountTransport`.
    let transport: (any PlexAccountTransport)?

    static var discoverBase: String {
        #if DEBUG
        if let override = ScreenshotMode.discoverBase { return override }
        #endif
        return "https://discover.provider.plex.tv"
    }

    /// plex.tv is a nicety for Home: a LAN-only session must not wait on it.
    private static let requestTimeout: TimeInterval = 8
    private static let pageSize = 100
    /// Large watchlists stop here; Home shows the newest ones anyway.
    private static let maxEntries = 500

    // MARK: - List

    private struct WatchlistPage: Decodable {
        struct Container: Decodable {
            let totalSize: Int?
            let size: Int?
            let Metadata: [FailableWatchlistEntry]?
        }
        let MediaContainer: Container
    }

    /// One undecodable entry (a type Plex added later) must not lose the list.
    private struct FailableWatchlistEntry: Decodable {
        let entry: PlexWatchlistEntryDTO?
        init(from decoder: any Decoder) throws {
            entry = try? PlexWatchlistEntryDTO(from: decoder)
        }
    }

    @MainActor func entries() async throws -> [WatchlistEntry] {
        let transport = try requireTransport()
        var entries: [WatchlistEntry] = []
        var start = 0
        while start < Self.maxEntries {
            let data = try await discoverRequest(
                path: "/library/sections/watchlist/all",
                queryItems: [
                    URLQueryItem(name: "sort", value: "watchlistedAt:desc"),
                    URLQueryItem(name: "includeCollections", value: "1"),
                    URLQueryItem(name: "includeExternalMedia", value: "1"),
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(Self.pageSize)),
                ]
            )
            let container = try transport.decodeJSON(WatchlistPage.self, from: data, serverID: nil).MediaContainer
            let page = container.Metadata ?? []
            entries += page.compactMap(\.entry).map(PlexUserContentMapper.watchlistEntry)
                .filter { $0.type == .movie || $0.type == .show }
            start += page.count
            guard !page.isEmpty, start < (container.totalSize ?? 0) else { break }
        }
        var seen = Set<String>()
        return entries.filter { seen.insert($0.guid).inserted }
    }

    // MARK: - Edits

    @MainActor func setWatchlisted(_ watchlisted: Bool, entry: WatchlistEntry) async throws {
        _ = try await discoverRequest(
            method: "PUT",
            path: watchlisted ? "/actions/addToWatchlist" : "/actions/removeFromWatchlist",
            queryItems: [URLQueryItem(name: "ratingKey", value: entry.itemID)]
        )
    }

    // MARK: - Details (titles not on a server)

    private struct MetadataPage: Decodable {
        struct Container: Decodable {
            let Metadata: [PlexWatchlistEntryDTO]?
            let Availability: [PlexWatchlistAvailabilityDTO]?
        }
        let MediaContainer: Container
    }

    @MainActor func details(itemID: String) async throws -> WatchlistEntry? {
        let transport = try requireTransport()
        let data = try await discoverRequest(path: "/library/metadata/\(itemID)")
        return try transport.decodeJSON(MetadataPage.self, from: data, serverID: nil).MediaContainer.Metadata?.first
            .map(PlexUserContentMapper.watchlistEntry)
    }

    @MainActor func availabilities(itemID: String) async throws -> [WatchlistAvailability] {
        let transport = try requireTransport()
        let data = try await discoverRequest(path: "/library/metadata/\(itemID)/availabilities")
        return (try transport.decodeJSON(MetadataPage.self, from: data, serverID: nil).MediaContainer.Availability ?? [])
            .map(PlexUserContentMapper.watchlistAvailability)
    }

    // MARK: - Plex's Home layout

    /// The rows of Plex's own Home, as Plex Web stores them. plex.tv keeps the
    /// `experience` setting per `X-Plex-Product` (verified: Dusk's own copy
    /// holds only the sidebar), and Plex Web's is the one where "Manage Home"
    /// lands. nil when it is the default layout or cannot be read.
    @MainActor func homeLayout() async -> [PlexHomeHubSetting]? {
        guard let transport,
              let token = transport.activeAccountToken?.nilIfEmpty,
              let url = client.buildURL(
                  base: MediaService.plexTVBase,
                  path: "/api/v2/user",
                  queryItems: [URLQueryItem(name: "includeSettings", value: "1")]
              ) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeout
        client.applyHeaders(to: &request, token: token)
        request.setValue("Plex Web", forHTTPHeaderField: "X-Plex-Product")

        guard let data = try? await transport.executeRequest(request, retriesFreshAuthentication: false, using: nil),
              let root = try? transport.decoder.decode(DuskJSONValue.self, from: data),
              let setting = root["settings"]?.arrayValue?.first(where: { $0["id"]?.stringValue == "experience" }),
              let blob = setting["value"]?.stringValue.flatMap(DuskJSONValue.decode(jsonString:)),
              let home = blob["homeSettings"],
              home["hasCustomizations"]?.boolValue == true,
              let hubs = home["hubs"]?.arrayValue, !hubs.isEmpty else { return nil }
        return hubs.compactMap(PlexHomeHubSetting.init(raw:))
    }

    // MARK: - Transport

    /// A plex.tv Discover request as the active profile. A 401 here is "this
    /// profile has no Watchlist", never a reason to re-authenticate.
    @MainActor private func discoverRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        let transport = try requireTransport()
        guard let token = transport.activeAccountToken?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }
        guard let url = client.buildURL(base: Self.discoverBase, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeout
        client.applyHeaders(to: &request, token: token)
        return try await transport.executeRequest(request, retriesFreshAuthentication: false, using: nil)
    }

    @MainActor private func requireTransport() throws -> any PlexAccountTransport {
        guard let transport else { throw PlexServiceError.notAuthenticated }
        return transport
    }
}

extension PlexAccountProvider {
    /// Nothing reads this yet: the facade builds the routed facet itself
    /// (`MediaService.watchlistProvider`), because the routing lives there.
    var watchlist: (any WatchlistProviding)? {
        PlexWatchlist(client: client, transport: nil)
    }
}
