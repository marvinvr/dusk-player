import Foundation

/// A row in a library section's Managed Recommendations, returned from
/// `GET /hubs/sections/{sectionId}/manage`.
///
/// These are the only Home rows Plex itself can reorder and show/hide, so they
/// are the part of Dusk's Home layout that can be written back to the server.
/// Ordering is limited to other hubs in the same library section.
/// Reading and writing them requires the server owner's token; shared users get
/// HTTP 403.
struct PlexManagedHub: Decodable, Sendable, Hashable, Identifiable {
    var id: String { identifier }

    /// Section-relative hub identifier (e.g. `movie.recentlyadded`,
    /// `custom.collection.1.4242`). The same hub appears in `GET /hubs` with the
    /// section id appended, which is how the two payloads are matched up.
    let identifier: String
    let title: String
    /// Whether the hub is currently on the owner's home screen.
    let promotedToOwnHome: Bool
    let promotedToRecommended: Bool
    let promotedToSharedHome: Bool
    let deletable: Bool

    enum CodingKeys: String, CodingKey {
        case identifier
        case title
        case promotedToOwnHome
        case promotedToRecommended
        case promotedToSharedHome
        case deletable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? identifier
        promotedToOwnHome = try container.decodeFlexibleBool(forKey: .promotedToOwnHome) ?? false
        promotedToRecommended = try container.decodeFlexibleBool(forKey: .promotedToRecommended) ?? false
        promotedToSharedHome = try container.decodeFlexibleBool(forKey: .promotedToSharedHome) ?? false
        deletable = try container.decodeFlexibleBool(forKey: .deletable) ?? true
    }
}

private extension KeyedDecodingContainer where Key == PlexManagedHub.CodingKeys {
    /// Plex answers these flags as JSON booleans, but the same fields come back
    /// as `1`/`0` from the XML-shaped responses older servers still emit.
    func decodeFlexibleBool(forKey key: Key) throws -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return nil
    }
}
