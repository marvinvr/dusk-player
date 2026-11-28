import Foundation

/// People: routes to the server's catalog facet (`CatalogProviding`).
extension MediaService {
    /// - Parameter serverID: Person ids are per-server tag ids, exactly like
    ///   rating keys, so a person route has to carry the server it came from.
    func getPerson(personID: String, serverID: String? = nil) async throws -> PersonDetails {
        try await catalog(on: resolveServerID(serverID)).person(id: personID)
    }

    /// Movies and shows only, without the account's hidden libraries, with
    /// same-title copies merged.
    func getPersonMedia(personID: String, serverID: String? = nil) async throws -> [MediaItem] {
        let items = try await catalog(on: resolveServerID(serverID)).personMedia(id: personID)

        let hiddenLibraries = await loadedHiddenLibraryFilter()
        let merged = MediaItemMerge.interleave([hiddenLibraries.filtering(items)
            .filter { $0.type == .movie || $0.type == .show }])
        registerAlternates(merged.alternates)
        return merged.items
    }
}
