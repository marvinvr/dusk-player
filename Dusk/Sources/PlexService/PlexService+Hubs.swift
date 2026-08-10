import Foundation

/// Managed Recommendations: the server-side hub layout behind the Plex home
/// screen. Dusk uses it so an edited Home layout follows the account to every
/// other Plex client instead of living only on this device.
///
/// Every call here is admin-only on the Plex side. Callers must check
/// `PlexService.canManageHubs` first and fall back to local preferences,
/// because a shared user's token answers 403.
extension PlexService {
    /// True when the connected server is owned by the active account, which is
    /// what the `/hubs/sections/{id}/manage` endpoints require.
    var canManageHubs: Bool {
        connectedServer?.owned == true
    }

    func getManagedHubs(sectionID: String) async throws -> [PlexManagedHub] {
        let data = try await rawServerRequest(path: managedHubsPath(sectionID: sectionID))
        let response = try decodeJSON(ManagedHubResponse.self, from: data)
        return response.MediaContainer.Hub ?? []
    }

    /// Shows or hides a hub. All three flags are sent on every call because Plex
    /// treats missing parameters as `false` and would silently demote the hub
    /// everywhere else it is promoted.
    func setManagedHubVisibility(
        sectionID: String,
        identifier: String,
        promotedToOwnHome: Bool,
        promotedToRecommended: Bool,
        promotedToSharedHome: Bool
    ) async throws {
        _ = try await rawServerRequest(
            method: "PUT",
            path: managedHubPath(sectionID: sectionID, identifier: identifier),
            queryItems: [
                URLQueryItem(name: "promotedToRecommended", value: promotedToRecommended.plexFlag),
                URLQueryItem(name: "promotedToOwnHome", value: promotedToOwnHome.plexFlag),
                URLQueryItem(name: "promotedToSharedHome", value: promotedToSharedHome.plexFlag),
            ]
        )
    }

    /// Moves a hub within its section's managed order.
    ///
    /// - Parameter after: the identifier this hub should follow, or `nil` to put
    ///   it first. The identifier belongs in the path: the documented
    ///   `/manage/move?identifier=` form is not implemented by shipping servers.
    func moveManagedHub(sectionID: String, identifier: String, after: String?) async throws {
        _ = try await rawServerRequest(
            method: "PUT",
            path: managedHubPath(sectionID: sectionID, identifier: identifier) + "/move",
            queryItems: after.map { [URLQueryItem(name: "after", value: $0)] }
        )
    }

    private func managedHubsPath(sectionID: String) -> String {
        "/hubs/sections/\(escapedPathComponent(sectionID))/manage"
    }

    private func managedHubPath(sectionID: String, identifier: String) -> String {
        "\(managedHubsPath(sectionID: sectionID))/\(escapedPathComponent(identifier))"
    }

    private func escapedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private extension Bool {
    var plexFlag: String { self ? "1" : "0" }
}

private struct ManagedHubResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let Hub: [PlexManagedHub]?
    }
}
