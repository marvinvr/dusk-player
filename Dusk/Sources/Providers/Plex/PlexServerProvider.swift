import Foundation

/// One Plex server (docs/jellyfin/04-architecture.md §3). It knows which server
/// it is, what the active profile may do on it, and holds the service's
/// `PlexClient`. Each facet is a value in its own file (`PlexCatalog.swift`,
/// …), filled in by the facet's wave-4 package.
final class PlexServerProvider: MediaServerProvider {
    let client: PlexClient
    let descriptor: ServerDescriptor
    let permissions: ServerPermissions

    init(client: PlexClient, seed: ServerSessionSeed) {
        self.client = client
        self.descriptor = ServerDescriptor(
            id: seed.serverID,
            name: seed.name,
            kind: .plex,
            version: seed.version,
            ownerLabel: seed.owned ? nil : seed.sourceTitle
        )
        self.permissions = Self.permissions(for: seed)
    }

    /// Today's Plex rules in neutral form. Hiding Home rows and installing
    /// subtitles need the server's owner on an unrestricted profile
    /// (`MediaService+HomeRows`, `+Subtitles`); playing, downloading and
    /// playlists are open to every account Plex shares a server with.
    static func permissions(for seed: ServerSessionSeed) -> ServerPermissions {
        let manages = seed.owned && !seed.restrictedProfile
        return ServerPermissions(
            canManageHomeRows: manages,
            canInstallSubtitles: manages,
            canDownload: true,
            canPlay: true,
            canEditPlaylists: true,
            ownerLabel: seed.owned ? nil : seed.sourceTitle
        )
    }
}
