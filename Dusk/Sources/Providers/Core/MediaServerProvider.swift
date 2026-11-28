import Foundation

/// One server, whatever runs it (docs/jellyfin/04-architecture.md §3). The
/// provider's `ProviderFactory` builds one per session and the pool stores it on
/// that `ServerSession`.
///
/// Each facet is a protocol in its own file. The facade routes every facet
/// call to the provider of the item's server (`MediaService.serverProvider(for:)`).
protocol MediaServerProvider: AnyObject, Sendable {
    var descriptor: ServerDescriptor { get }
    /// What the active profile may do on this server, read live: the profile
    /// can change while the session stays.
    @MainActor var permissions: ServerPermissions { get }

    // Required: both platforms can do these.
    var catalog: any CatalogProviding { get }
    var home: any HomeProviding { get }
    var playback: any PlaybackProviding { get }
    var userData: any UserDataProviding { get }
    var markers: any MarkerProviding { get }
    var images: any ImageProviding { get }
    var playlists: any PlaylistProviding { get }
    var downloads: any DownloadProviding { get }

    // Optional: nil means the platform or this server does not have it.
    var liveTV: (any LiveTVProviding)? { get }
    var subtitleSearch: (any SubtitleSearchProviding)? { get }
    var rating: (any UserRatingProviding)? { get }
}

/// Who a server is: id, name, provider, version and owner.
struct ServerDescriptor: Sendable, Hashable {
    let id: String
    let name: String
    let kind: ProviderKind
    let version: String?
    /// The owner's name for a server shared with the account ("Shared by X");
    /// nil for one the account owns.
    let ownerLabel: String?
}

/// What a factory gets to build the provider for one server session.
struct ServerSessionSeed: Sendable, Hashable {
    let serverID: String
    let name: String
    let version: String?
    let owned: Bool
    let sourceTitle: String?
}
