import Foundation

/// One Plex server (docs/jellyfin/04-architecture.md §3). It knows which server
/// it is and what the active profile may do on it, and hands its account's
/// routed send (`PlexServerRouter`) to every facet. Each facet is a value in
/// its own file (`PlexCatalog.swift`, …).
///
/// An empty `descriptor.id` is the primary-tracking provider the facade uses
/// for a nil server id: its facets pass nil on, so every request resolves the
/// highest-priority server when it is sent, as it always has.
final class PlexServerProvider: MediaServerProvider {
    let client: PlexClient
    let router: PlexServerRouter
    let descriptor: ServerDescriptor
    let permissions: ServerPermissions

    /// The id the facets send to; nil for the primary-tracking provider.
    var routedServerID: String? { descriptor.id.nilIfEmpty }

    init(router: PlexServerRouter, seed: ServerSessionSeed) {
        self.client = router.client
        self.router = router
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
