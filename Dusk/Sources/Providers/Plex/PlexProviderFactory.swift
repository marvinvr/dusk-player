import Foundation

/// Builds Plex's providers. Carries the service's `PlexClient`, so every server
/// provider shares its sessions and headers.
struct PlexProviderFactory: ProviderFactory {
    let client: PlexClient

    var kind: ProviderKind { .plex }

    func makeServerProvider(_ seed: ServerSessionSeed) -> any MediaServerProvider {
        PlexServerProvider(client: client, seed: seed)
    }
}
