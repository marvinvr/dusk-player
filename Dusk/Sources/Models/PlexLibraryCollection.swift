import Foundation

/// A collection inside a library section, loaded from the section's
/// `collection` filter values (e.g. one collection per channel in an
/// "Other Videos" library).
struct PlexLibraryCollection: Sendable, Hashable, Identifiable {
    /// Collection tag ids are per-server, so the server belongs in the identity.
    var id: String {
        guard let serverID else { return key }
        return "\(serverID)|\(key)"
    }

    /// The server whose library section this collection belongs to.
    let serverID: String?

    /// Plain filter value: pass it as `filters: ["collection": key]` to
    /// `getLibraryItems(sectionId:)` / `getLibraryItemCount(sectionId:)`.
    let key: String
    let title: String

    init(serverID: String?, key: String, title: String) {
        self.serverID = serverID
        self.key = key
        self.title = title
    }
}

extension PlexLibraryCollection {
    /// Builds a collection from a `/library/sections/{id}/collection` filter
    /// Directory entry. Depending on server version the entry's key is a plain
    /// tag id, an `.../all?collection=<id>` fast key, or a path ending in the
    /// id, so the plain value is extracted the same way
    /// `LibraryGenreSupport.extractFilterValue` handles genre keys.
    init?(filterValue: PlexLibraryFilterValue, serverID: String? = nil) {
        let rawKey = filterValue.key
        let extractedKey: String?

        if let components = URLComponents(string: rawKey),
           let value = components.queryItems?.first(where: { $0.name == "collection" })?.value {
            extractedKey = value
        } else if rawKey.hasPrefix("/") {
            extractedKey = rawKey.split(separator: "/").last.map(String.init)
        } else {
            extractedKey = rawKey.nilIfEmpty
        }

        guard let key = extractedKey, !key.isEmpty else { return nil }

        self.serverID = serverID
        self.key = key
        self.title = filterValue.title
    }
}
