import Foundation

/// Which rows are on Home, through the server's own switch (for Plex the
/// "Home" column of Plex Web's per-library Manage Recommendations,
/// `promotedToOwnHome`; see `PlexHomeRows`).
///
/// `GET /hubs` honours it on the server, so a row hidden here leaves Home in
/// Plex Web and every other Plex app too, and Home needs no filter of its own.
/// (Plex Web's `experience.homeSettings.hubs` is a pre-2024 layout that
/// current Plex Web only migrates and never renders — do not write to it.)
extension MediaService {
    /// Only the server owner can change a library's rows, and restricted Home
    /// profiles cannot at all. Per server: the account can own one server and
    /// merely be shared another.
    func canManageHomeRows(serverID: String) -> Bool {
        guard pool.connection(for: serverID) != nil else { return false }
        return serverProvider(for: serverID).permissions.canManageHomeRows
    }

    func getManagedHubs(sectionId: String, serverID: String) async throws -> [ManagedHub] {
        try await home(on: resolveServerID(serverID)).managedRows(libraryID: sectionId)
    }

    func setManagedHub(_ hub: ManagedHub, sectionId: String, serverID: String) async throws {
        try await home(on: resolveServerID(serverID)).setManagedRow(hub, libraryID: sectionId)
    }

    /// The Manage Recommendations entries behind one Home row: one per owned
    /// server and library the (possibly merged) row draws from.
    func managedHomeRows(for hub: HomeRow) async -> [ManagedHomeRow] {
        var rows: [ManagedHomeRow] = []
        for source in hub.sources where canManageHomeRows(serverID: source.serverID) {
            let libraryIDs = libraryOrder.sections.filter { $0.serverID == source.serverID }.map(\.key)
            if let row = await home(on: source.serverID).managedRow(for: hub, source: source, libraryIDs: libraryIDs) {
                rows.append(row)
            }
        }
        return rows
    }

    /// Whether Home may offer to hide a row, without asking any server yet:
    /// the row has a switch (`HomeRow.canHide`) and the user may flip it on at
    /// least one of its servers.
    func canHideHomeRow(_ hub: HomeRow) -> Bool {
        hub.canHide && hub.sources.contains { canManageHomeRows(serverID: $0.serverID) }
    }
}
