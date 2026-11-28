import Foundation

/// Plex's `CatalogProviding`. Empty until P0-07 moves the Plex calls here.
struct PlexCatalog: CatalogProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var catalog: any CatalogProviding { PlexCatalog(client: client) }
}
