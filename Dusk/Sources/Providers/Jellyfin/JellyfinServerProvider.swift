import Foundation

/// One Jellyfin server as the active user sees it (docs/jellyfin/04-architecture.md
/// §3). Its permissions are that user's `Policy`; its facets build a
/// `JellyfinClient` for each request from the live session (`client()`).
///
/// Images are J-03's `JellyfinImages`. The other facets are placeholders that
/// answer empty until their packages land (catalog J-02, home J-04, playback,
/// user data and markers J-05, playlists J-07, downloads J-08a); Live TV
/// (J-09) and subtitle search (J-11) stay nil until then.
final class JellyfinServerProvider: MediaServerProvider {
    let descriptor: ServerDescriptor
    let account: JellyfinAccountProvider

    init(account: JellyfinAccountProvider, seed: ServerSessionSeed) {
        self.account = account
        self.descriptor = ServerDescriptor(
            id: JellyfinID.normalized(seed.serverID),
            name: seed.name,
            kind: .jellyfin,
            version: seed.version,
            ownerLabel: nil
        )
    }

    /// The active user's policy, read live: Switch User changes it while the
    /// app runs, and every launch refreshes it from `/Users/Me`.
    @MainActor var permissions: ServerPermissions {
        let policy = account.record(forServer: descriptor.id)?.policy ?? .serverDefaults
        return policy.permissions
    }

    /// A client for the active user on the session's live endpoint. Throws
    /// while no user of this server is signed in.
    @MainActor
    func client() throws -> JellyfinClient {
        guard let record = account.record(forServer: descriptor.id),
              let client = account.client(for: record) else {
            throw MediaServiceError.notAuthenticated
        }
        return client
    }

    var catalog: any CatalogProviding { JellyfinCatalog(server: self) }
    var home: any HomeProviding { JellyfinHome(server: self) }
    var playback: any PlaybackProviding { JellyfinPlayback(server: self) }
    var userData: any UserDataProviding { JellyfinUserData(server: self) }
    var markers: any MarkerProviding { JellyfinMarkers(server: self) }
    var images: any ImageProviding { JellyfinImages() }
    var playlists: any PlaylistProviding { JellyfinPlaylists(server: self) }
    var downloads: any DownloadProviding { JellyfinDownloads(server: self) }
    var liveTV: (any LiveTVProviding)? { nil }
    var subtitleSearch: (any SubtitleSearchProviding)? { nil }
    var rating: (any UserRatingProviding)? { nil }
}
