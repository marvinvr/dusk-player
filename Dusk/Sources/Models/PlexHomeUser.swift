import Foundation

/// A member returned from the Plex Home users endpoint.
///
/// This is intentionally tokenless. Switching users returns a short-lived
/// response containing an account token, but that token is handled directly by
/// `PlexService` and is never retained in a model that can reach the UI.
struct PlexHomeUser: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let uuid: String?
    let username: String?
    let title: String?
    let friendlyName: String?
    let thumb: String?
    let isProtected: Bool
    let isRestricted: Bool
    let isAdmin: Bool
    let isGuest: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case username
        case title
        case friendlyName
        case thumb
        case protected
        case restricted
        case admin
        case guest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let value = try? container.decode(Int.self, forKey: .id) {
            id = value
        } else if let value = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(value) {
            id = parsed
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Plex Home user is missing an id"
                )
            )
        }

        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)?.nilIfEmpty
        username = try container.decodeIfPresent(String.self, forKey: .username)?.nilIfEmpty
        title = try container.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty
        friendlyName = try container.decodeIfPresent(String.self, forKey: .friendlyName)?.nilIfEmpty
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)?.nilIfEmpty
        isProtected = Self.decodeFlexibleBool(container, forKey: .protected) ?? false
        isRestricted = Self.decodeFlexibleBool(container, forKey: .restricted) ?? false
        isAdmin = Self.decodeFlexibleBool(container, forKey: .admin) ?? false
        isGuest = Self.decodeFlexibleBool(container, forKey: .guest) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(uuid, forKey: .uuid)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(friendlyName, forKey: .friendlyName)
        try container.encodeIfPresent(thumb, forKey: .thumb)
        try container.encode(isProtected, forKey: .protected)
        try container.encode(isRestricted, forKey: .restricted)
        try container.encode(isAdmin, forKey: .admin)
        try container.encode(isGuest, forKey: .guest)
    }

    var displayName: String {
        friendlyName ?? title ?? username ?? "Plex User"
    }

    var avatarURL: URL? {
        thumb.flatMap(URL.init(string:))
    }

    /// Stable, non-secret identity used to scope downloads and local state.
    var stableProfileID: String {
        uuid ?? "plex-home-\(id)"
    }

    private static func decodeFlexibleBool(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
