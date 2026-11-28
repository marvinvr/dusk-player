import Foundation

/// Jellyfin's catalog. Placeholder until J-02: every list is empty; an
/// item's details load for the player (J-05).
@MainActor
struct JellyfinCatalog: CatalogProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    func libraries() async throws -> [Library] { [] }

    func items(
        libraryID: String,
        kind: LibraryKind?,
        start: Int,
        size: Int,
        sort: LibrarySortOption?,
        filter: LibraryFilter
    ) async throws -> [MediaItem] { [] }

    func itemCount(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> Int { 0 }

    func letterCounts(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> [LibraryLetterCount] { [] }

    func sortFields(for kind: LibraryKind?) -> [LibrarySortField] { LibrarySortField.fields(for: kind) }

    func filterFields(libraryID: String, includesCollection: Bool) async throws -> [LibraryFilterField] { [] }

    func filterChoices(for field: LibraryFilterField) async throws -> [LibraryFilterChoice] { [] }

    func channelCollections(libraryID: String) async throws -> [MediaCollection] { [] }

    func collections(libraryID: String, start: Int, size: Int) async throws -> MediaItemPage {
        MediaItemPage(items: [], totalSize: 0, start: start, requestedSize: size)
    }

    func collectionItems(collectionID: String, start: Int, size: Int, sort: LibrarySortOption?) async throws -> MediaItemPage {
        MediaItemPage(items: [], totalSize: 0, start: start, requestedSize: size)
    }

    func collection(itemID: String) async throws -> MediaItem? { nil }

    func collectionMode(libraryID: String) async -> LibraryCollectionMode { .showItems }

    /// With its skip markers (J-05, `JellyfinItemDetails`). `checkFiles` has
    /// no Jellyfin counterpart.
    func details(itemID: String, checkFiles: Bool) async throws -> MediaDetails {
        try await JellyfinItemDetails.load(itemID: itemID, serverID: server.descriptor.id, client: server.client())
    }

    func seasons(showID: String) async throws -> [Season] { [] }

    func episodes(seasonID: String) async throws -> [Episode] { [] }

    func allEpisodes(showID: String) async throws -> [Episode] { [] }

    func person(id: String) async throws -> PersonDetails {
        throw MediaServiceError.notImplemented
    }

    func personMedia(id: String) async throws -> [MediaItem] { [] }

    func extras(itemID: String) async throws -> [Extra] { [] }

    func searchGroups(query: String) async throws -> [HomeRow] { [] }

    func photoPage(libraryID: String, query: PhotoQuery, start: Int, size: Int) async throws -> PhotoPage {
        PhotoPage(items: [], totalSize: 0)
    }
}
