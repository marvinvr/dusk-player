import Foundation

/// The media-server provider behind a server id (docs/jellyfin/04-architecture.md §6.1).
enum ProviderKind: String, Codable, Sendable, Hashable {
    case plex
    case jellyfin
}

/// What Dusk knows about a server beyond its id.
struct ServerRecord: Codable, Sendable, Hashable {
    let kind: ProviderKind
    let accountID: String?
    let name: String?
}

/// Which provider each `serverID` belongs to. **A server id with no record is
/// Plex**: that is every id persisted before Jellyfin support, so nothing on
/// disk needs a record to keep working.
///
/// Lookup only for now: nothing registers a server yet and nothing is stored.
/// Persisting records arrives with the first provider that needs one.
struct ServerRegistry: Sendable {
    private var records: [String: ServerRecord] = [:]

    init(records: [String: ServerRecord] = [:]) {
        self.records = records
    }

    func record(for serverID: String) -> ServerRecord? {
        records[serverID]
    }

    func kind(for serverID: String?) -> ProviderKind {
        serverID.flatMap { records[$0]?.kind } ?? .plex
    }

    mutating func register(_ record: ServerRecord, for serverID: String) {
        records[serverID] = record
    }
}
