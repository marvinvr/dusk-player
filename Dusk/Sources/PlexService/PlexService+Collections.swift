import Foundation

/// One page of a paged collection listing, with the server's total when it
/// sends one.
struct MediaItemPage: Sendable {
    let items: [MediaItem]
    let totalSize: Int?
    let start: Int
    let requestedSize: Int

    var hasMore: Bool {
        if let totalSize { return start + items.count < totalSize }
        return items.count >= requestedSize
    }
}

/// A movie or TV library's "Collections" advanced setting (`collectionMode`
/// in the section's prefs).
enum PlexLibraryCollectionMode: String, Sendable {
    /// Collections are switched off for the library: nothing offers them.
    case disabled = "0"
    /// The library grid shows a collection in place of the titles inside it.
    case hideItems = "1"
    /// Collections and their titles both appear (Plex's default).
    case showItems = "2"
}

/// Plex collections: manual and smart collections are both metadata items of
/// type `collection`, listed per section and expanded through `/children`
/// (the server resolves a smart collection's filter there).
extension PlexService {
    func getCollections(
        sectionId: String,
        start: Int = 0,
        size: Int = 50,
        serverID: String? = nil
    ) async throws -> MediaItemPage {
        try await fetchItemPage(
            path: "/library/sections/\(sectionId)/collections",
            start: start,
            size: size,
            serverID: serverID
        )
    }

    /// A collection's titles, in the collection's own sort order, or in
    /// `sort` (a Plex sort value such as `titleSort:desc`) when given.
    func getCollectionItems(
        itemID: String,
        start: Int = 0,
        size: Int = 50,
        sort: String? = nil,
        serverID: String? = nil
    ) async throws -> MediaItemPage {
        try await fetchItemPage(
            path: "/library/metadata/\(itemID)/children",
            start: start,
            size: size,
            extraQueryItems: sort.map { [URLQueryItem(name: "sort", value: $0)] } ?? [],
            serverID: serverID
        )
    }

    /// The collection itself (title, summary, artwork, count).
    func getCollection(itemID: String, serverID: String? = nil) async throws -> MediaItem? {
        let items: [MediaItem] = try await fetchMetadata(
            path: "/library/metadata/\(itemID)",
            serverID: serverID
        )
        return items.first
    }

    /// The library's collection display setting. Shared users may not be
    /// allowed to read a section's prefs; anything unreadable is Plex's
    /// default, so collections stay visible.
    func collectionMode(sectionId: String, serverID: String? = nil) async -> PlexLibraryCollectionMode {
        guard let targetID = try? resolveServerID(serverID) else { return .showItems }
        let cacheKey = "\(targetID)|\(sectionId)"
        if let cached = PlexLibraryCollectionModeCache.modes[cacheKey] { return cached }

        do {
            let data = try await rawServerRequest(
                path: "/library/sections/\(sectionId)/prefs",
                serverID: targetID
            )
            let settings = try decodeJSON(SectionPrefsResponse.self, from: data, serverID: targetID)
                .MediaContainer.Setting ?? []
            let mode = settings.first { $0.id == "collectionMode" }
                .flatMap { $0.value.flatMap(PlexLibraryCollectionMode.init(rawValue:)) } ?? .showItems
            PlexLibraryCollectionModeCache.modes[cacheKey] = mode
            return mode
        } catch {
            return .showItems
        }
    }

    private func fetchItemPage(
        path: String,
        start: Int,
        size: Int,
        extraQueryItems: [URLQueryItem] = [],
        serverID: String?
    ) async throws -> MediaItemPage {
        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(
            path: path,
            queryItems: [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
            ] + extraQueryItems,
            serverID: targetID
        )
        let container = try decodeJSON(MetadataResponse<MediaItem>.self, from: data, serverID: targetID)
            .MediaContainer
        return MediaItemPage(
            items: container.Metadata ?? [],
            totalSize: container.totalSize,
            start: start,
            requestedSize: size
        )
    }
}

/// Section settings rarely change while the app runs; one read per section
/// per launch is enough.
@MainActor
private enum PlexLibraryCollectionModeCache {
    static var modes: [String: PlexLibraryCollectionMode] = [:]
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
