import Foundation

/// One row of a library's "Manage Recommendations" list in Plex Web
/// (`GET /hubs/sections/{id}/manage`). `promotedToOwnHome` is what puts the
/// row on the owner's Home — in every Plex app, since `GET /hubs` honours it.
///
/// The identifier is the row kind, not the row: `movie.curated` here is
/// `movie.curated.2.1` ("Oh, The Horror!") in `GET /hubs`. See
/// `matches(hubIdentifier:sectionID:)`.
struct PlexManagedHub: Decodable, Sendable, Hashable, Identifiable {
    let identifier: String
    let title: String
    let promotedToRecommended: Bool
    let promotedToOwnHome: Bool
    let promotedToSharedHome: Bool

    var id: String { identifier }

    enum CodingKeys: String, CodingKey {
        case identifier, title, promotedToRecommended, promotedToOwnHome, promotedToSharedHome
    }

    init(
        identifier: String,
        title: String,
        promotedToRecommended: Bool = false,
        promotedToOwnHome: Bool = false,
        promotedToSharedHome: Bool = false
    ) {
        self.identifier = identifier
        self.title = title
        self.promotedToRecommended = promotedToRecommended
        self.promotedToOwnHome = promotedToOwnHome
        self.promotedToSharedHome = promotedToSharedHome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? identifier
        func flag(_ key: CodingKeys) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key))
                ?? (try? container.decodeIfPresent(Int.self, forKey: key)).map { $0 != 0 }
                ?? false
        }
        promotedToRecommended = flag(.promotedToRecommended)
        promotedToOwnHome = flag(.promotedToOwnHome)
        promotedToSharedHome = flag(.promotedToSharedHome)
    }

    func withOwnHome(_ onHome: Bool) -> PlexManagedHub {
        PlexManagedHub(
            identifier: identifier,
            title: title,
            promotedToRecommended: promotedToRecommended,
            promotedToOwnHome: onHome,
            promotedToSharedHome: promotedToSharedHome
        )
    }

    /// Whether a `GET /hubs` row of section `sectionID` is this entry.
    ///
    /// Built-in rows append the section and a variant to the kind
    /// (`movie.curated` → `movie.curated.2.1`); collection rows already carry
    /// their section (`custom.collection.1.99487` → `….99487.99487`).
    func matches(hubIdentifier: String, sectionID: String) -> Bool {
        guard hubIdentifier != identifier else { return true }
        guard hubIdentifier.hasPrefix(identifier + ".") else { return false }
        if identifier.split(separator: ".").contains(Substring(sectionID)) { return true }
        let rest = hubIdentifier.dropFirst(identifier.count + 1).split(separator: ".")
        return rest.first == Substring(sectionID)
    }
}

/// The Manage Recommendations entry behind (part of) a Home row.
struct PlexManagedHomeRow: Sendable, Hashable {
    let serverID: String
    let sectionID: String
    let hub: PlexManagedHub
}
