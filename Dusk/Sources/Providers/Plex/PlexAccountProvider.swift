import Foundation

/// The signed-in plex.tv account (docs/jellyfin/04-architecture.md §3, §7). A
/// shell for now that owns the service's `PlexClient`; sign-in, discovery,
/// probing and sign-out stay in the facade until the account layer (P0-16).
/// Each facet is an empty value in its own file.
final class PlexAccountProvider: MediaAccountProvider {
    let client: PlexClient

    init(client: PlexClient) {
        self.client = client
    }
}
