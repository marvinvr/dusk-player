import Foundation

/// What the signed-in user may do on one server (docs/jellyfin/04-architecture.md
/// §3): the neutral form of Plex's `owned` flag and restricted Home profiles, and
/// of Jellyfin's `User.Policy`. A view checks these instead of a provider kind.
struct ServerPermissions: Sendable, Hashable {
    var canManageHomeRows: Bool
    var canInstallSubtitles: Bool
    var canDownload: Bool
    var canPlay: Bool
    var canEditPlaylists: Bool
    /// "Shared by X"; nil for a server the account owns.
    var ownerLabel: String?
}
