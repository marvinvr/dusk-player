import Foundation

/// Which Plex rows are on Home, through Plex's own switch: the "Home" column
/// of Plex Web's per-library Manage Recommendations (`promotedToOwnHome`).
///
/// `GET /hubs` honours it on the server, so a row hidden here leaves Home in
/// Plex Web and every other Plex app too, and Home needs no filter of its own.
/// (Plex Web's `experience.homeSettings.hubs` is a pre-2024 layout that
/// current Plex Web only migrates and never renders — do not write to it.)
extension PlexService {
    /// Only the server owner can change a library's rows, and restricted Home
    /// profiles cannot at all. Per server: the account can own one server and
    /// merely be shared another.
    func canManageHomeRows(serverID: String) -> Bool {
        guard let connection = pool.connection(for: serverID) else { return false }
        return connection.owned && activeHomeUser?.isRestricted != true
    }

    func getManagedHubs(sectionId: String, serverID: String) async throws -> [PlexManagedHub] {
        let data = try await rawServerRequest(
            path: "/hubs/sections/\(sectionId)/manage",
            serverID: serverID
        )
        return try decodeJSON(ManagedHubResponse.self, from: data).MediaContainer.Hub ?? []
    }

    /// Plex Web sends all three flags on every change, so the other two are
    /// sent back as they were.
    func setManagedHub(_ hub: PlexManagedHub, sectionId: String, serverID: String) async throws {
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/hubs/sections/\(sectionId)/manage/\(hub.identifier)",
            queryItems: [
                URLQueryItem(name: "promotedToRecommended", value: flag(hub.promotedToRecommended)),
                URLQueryItem(name: "promotedToOwnHome", value: flag(hub.promotedToOwnHome)),
                URLQueryItem(name: "promotedToSharedHome", value: flag(hub.promotedToSharedHome)),
            ],
            serverID: serverID
        )
    }

    /// The Manage Recommendations entries behind one Home row: one per owned
    /// server and library the (possibly merged) row draws from.
    ///
    /// `GET /hubs` rows usually carry no `libraryID`, and the numbers
    /// in their identifier are not reliably the section (`movie.curated.2.1`),
    /// so the section comes from the row's titles when they say, else every
    /// library on that server is asked.
    func managedHomeRows(for hub: HomeRow) async -> [PlexManagedHomeRow] {
        var rows: [PlexManagedHomeRow] = []
        for source in hub.sources where canManageHomeRows(serverID: source.serverID) {
            let representative = source.serverID == hub.sources.first?.serverID
            guard let identifier = (source.hubIdentifier ?? (representative ? hub.hubIdentifier : nil))?.nilIfEmpty,
                  !identifier.hasPrefix("home.") else { continue }

            var sectionIDs = Set(hub.items.filter { $0.serverID == source.serverID }.compactMap(\.libraryID))
            if representative, let sectionID = hub.libraryID?.nilIfEmpty {
                sectionIDs.insert(sectionID)
            }
            let candidates = sectionIDs.isEmpty
                ? libraryOrder.sections.filter { $0.serverID == source.serverID }.map(\.key)
                : Array(sectionIDs)

            for sectionID in candidates {
                guard let managed = try? await getManagedHubs(sectionId: sectionID, serverID: source.serverID),
                      let match = managed.first(where: { $0.matches(hubIdentifier: identifier, sectionID: sectionID) })
                else { continue }
                rows.append(PlexManagedHomeRow(serverID: source.serverID, sectionID: sectionID, hub: match))
                break
            }
        }
        return rows
    }

    /// Whether Home may offer to hide a row, without asking any server yet.
    /// Account-wide rows (`home.*`: Continue Watching, the type-wide Recently
    /// Added) are not in any library's list.
    func canHideHomeRow(_ hub: HomeRow) -> Bool {
        guard let identifier = hub.hubIdentifier, !identifier.hasPrefix("home.") else { return false }
        return hub.sources.contains { canManageHomeRows(serverID: $0.serverID) }
    }
}

private struct ManagedHubResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Hub: [PlexManagedHub]?
    }
}
