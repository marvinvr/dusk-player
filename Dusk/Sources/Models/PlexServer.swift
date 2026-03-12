import Foundation

/// A Plex Media Server returned from `GET https://plex.tv/api/v2/resources`.
struct PlexServer: Codable, Sendable, Identifiable {
    var id: String { clientIdentifier }

    let name: String
    let clientIdentifier: String
    let product: String?
    let productVersion: String?
    let platform: String?
    let platformVersion: String?
    let provides: String?
    let owned: Bool
    let presence: Bool
    let accessToken: String?
    let sourceTitle: String?
    let connections: [PlexConnection]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        clientIdentifier = try container.decode(String.self, forKey: .clientIdentifier)
        provides = try container.decodeIfPresent(String.self, forKey: .provides)
        product = try container.decodeIfPresent(String.self, forKey: .product)
        productVersion = try container.decodeIfPresent(String.self, forKey: .productVersion)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        platformVersion = try container.decodeIfPresent(String.self, forKey: .platformVersion)
        owned = try container.decodeIfPresent(Bool.self, forKey: .owned) ?? false
        presence = try container.decodeIfPresent(Bool.self, forKey: .presence) ?? false
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        connections = try container.decodeIfPresent([PlexConnection].self, forKey: .connections) ?? []
    }

    /// Returns connections sorted by preference: local first, then remote, then relay.
    var sortedConnections: [PlexConnection] {
        connections.sorted { lhs, rhs in
            if lhs.local != rhs.local { return lhs.local }
            if lhs.relay != rhs.relay { return !lhs.relay }
            return false
        }
    }
}

/// A single connection endpoint for a Plex server (local, remote, or relay).
struct PlexConnection: Codable, Sendable, Hashable {
    let `protocol`: String
    let address: String
    let port: Int
    let uri: String
    let local: Bool
    let relay: Bool
    let iPv6: Bool?

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case address
        case port
        case uri
        case local
        case relay
        case iPv6 = "IPv6"
    }
}
