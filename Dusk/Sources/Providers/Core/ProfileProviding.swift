import Foundation

/// One profile on an account (docs/jellyfin/04-architecture.md §7.3): a Plex
/// Home member today, a Jellyfin user later. What the profile picker and
/// Settings show; never carries a credential.
struct Profile: Sendable, Hashable, Identifiable {
    /// The storage scope id while this profile is active (`activeProfileID`).
    /// Stable across launches; downloads, pinned playlists and remembered
    /// tracks are filed under it.
    let id: String
    /// The provider's own id for the profile, opaque to everything above it.
    let nativeID: String
    let displayName: String
    let avatarURL: URL?
    /// Switching to it asks for a secret first (a Plex Home PIN).
    let isProtected: Bool
    let isAdmin: Bool
    let isRestricted: Bool
}

/// Profiles on an account: list, current, whether there is anything to switch
/// to. The switch itself stays a facade verb (`MediaService.switchProfile`)
/// because it tears down every server session; it joins this protocol with the
/// second provider (J-01), whose secret is a password rather than a PIN.
protocol ProfileProviding: Sendable {
    /// More than one profile to choose from.
    @MainActor var canSwitch: Bool { get }
    @MainActor var all: [Profile] { get }
    @MainActor var current: Profile? { get }
}
