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

    private init(
        name: String,
        clientIdentifier: String,
        product: String?,
        productVersion: String?,
        platform: String?,
        platformVersion: String?,
        provides: String?,
        owned: Bool,
        presence: Bool,
        accessToken: String?,
        sourceTitle: String?,
        connections: [PlexConnection]
    ) {
        self.name = name
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.productVersion = productVersion
        self.platform = platform
        self.platformVersion = platformVersion
        self.provides = provides
        self.owned = owned
        self.presence = presence
        self.accessToken = accessToken
        self.sourceTitle = sourceTitle
        self.connections = connections
    }

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
            if lhs.sortPriority != rhs.sortPriority {
                return lhs.sortPriority < rhs.sortPriority
            }

            if lhs.isHTTPS != rhs.isHTTPS {
                return lhs.isHTTPS
            }

            return false
        }
    }

    var usableAccessToken: String? {
        accessToken?.nilIfEmpty
    }

    /// Server snapshots live in UserDefaults, while credentials belong only in
    /// Keychain. Older Dusk versions persisted `accessToken` as part of this
    /// model; bootstrap migrates that token once and rewrites a tokenless copy.
    var withoutAccessToken: PlexServer {
        PlexServer(
            name: name,
            clientIdentifier: clientIdentifier,
            product: product,
            productVersion: productVersion,
            platform: platform,
            platformVersion: platformVersion,
            provides: provides,
            owned: owned,
            presence: presence,
            accessToken: nil,
            sourceTitle: sourceTitle,
            connections: connections
        )
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

    var sortPriority: Int {
        if local && !relay { return 0 }
        if !local && !relay { return 1 }
        return 2
    }

    var isHTTPS: Bool {
        `protocol`.caseInsensitiveCompare("https") == .orderedSame
    }

    var isKnownUnreachableAddress: Bool {
        let normalized = address
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "-", with: ":")
            .lowercased()

        if normalized.hasPrefix("172.") {
            let octets = normalized.split(separator: ".")
            if octets.count > 1, let secondOctet = Int(octets[1]), (17...31).contains(secondOctet) {
                return true
            }
        }

        if normalized == "::" || normalized == "0000:0000:0000:0000:0000:0000:0000:0000" {
            return true
        }

        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("fe80::") {
            return true
        }

        return false
    }

    var httpFallbackURI: String? {
        guard isHTTPS else { return nil }

        let host: String
        if address.contains(":") && !address.hasPrefix("[") && !address.hasSuffix("]") {
            host = "[\(address)]"
        } else {
            host = address
        }

        return "http://\(host):\(port)"
    }
}
