import Foundation

/// The currently authenticated Plex account returned from `GET https://plex.tv/user`.
struct PlexUser: Codable, Sendable, Identifiable {
    let id: Int
    let username: String?
    let title: String?
    let friendlyName: String?
    let thumb: String?
}

/// The `subscription` object on a Plex account (`GET https://plex.tv/api/v2/user`).
/// `isActive` is the entitlement signal we care about: it is true when the
/// account carries any active paid subscription (Plex Pass or the cheaper
/// Remote Watch Pass), both of which unlock remote streaming of personal media.
struct PlexSubscription: Decodable, Sendable {
    let isActive: Bool?
    let status: String?
    let plan: String?

    enum CodingKeys: String, CodingKey {
        case active
        case status
        case plan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isActive = Self.decodeFlexibleBool(container, forKey: .active)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
    }

    // Plex sends `active` as a JSON bool in api/v2, but tolerate int/string
    // shapes the way the rest of the model layer does for flag fields.
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
            case "1", "true", "active", "yes": return true
            case "0", "false", "inactive", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
