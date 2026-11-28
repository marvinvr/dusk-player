import Foundation

/// One Plex server (docs/jellyfin/04-architecture.md §3). A shell for now: it
/// knows which server it is and holds the service's `PlexClient`. Each facet
/// is an empty value in its own file (`PlexCatalog.swift`, …), which the
/// facet's wave-4 package fills in.
final class PlexServerProvider: MediaServerProvider {
    let client: PlexClient
    let descriptor: ServerDescriptor

    init(client: PlexClient, seed: ServerSessionSeed) {
        self.client = client
        self.descriptor = ServerDescriptor(
            id: seed.serverID,
            name: seed.name,
            kind: .plex,
            version: seed.version,
            ownerLabel: seed.owned ? nil : seed.sourceTitle
        )
    }
}
