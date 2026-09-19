import Foundation

/// Editing state for the Server Priority screen.
///
/// The stored order (`ServerPriorityStore`) is the source of truth and every
/// edit is written immediately — there is nothing to save and nothing to lose
/// by leaving the screen. The rows are derived from the store plus the live
/// pool state, so a server that connects while the screen is open updates in
/// place.
@MainActor
@Observable
final class ServerPrioritySettingsViewModel {
    struct Row: Identifiable, Equatable {
        /// The server's machine identifier.
        let id: String
        let name: String
        /// "Your server" / "Shared by X".
        let ownership: String
        /// Local / Remote / Relay / Connecting… / Offline / Not authorized /
        /// Disabled.
        let status: String
        let isEnabled: Bool
        /// Drives the accent-colored status text; only a live session earns it.
        let isConnected: Bool
    }

    private let plexService: PlexService
    private let connections: ServerConnectionCoordinator

    /// Servers whose session is being (re-)established from this screen, so the
    /// row can say "Connecting…" the instant the switch is flipped.
    private var pendingServerIDs: Set<String> = []

    init(plexService: PlexService, connections: ServerConnectionCoordinator) {
        self.plexService = plexService
        self.connections = connections
    }

    // MARK: - Reading

    var rows: [Row] {
        let pool = plexService.pool
        let priority = plexService.serverPriority

        // The stored order decides the list; servers the store has not ranked
        // yet (discovered seconds ago) follow in the pool's own order.
        var identifiers = priority.entries
            .map(\.machineIdentifier)
            .filter { pool.server(for: $0) != nil }
        let ranked = Set(identifiers)
        identifiers += pool.priorityOrderedIdentifiers.filter {
            !ranked.contains($0) && pool.server(for: $0) != nil
        }

        return identifiers.compactMap { serverID in
            guard let server = pool.server(for: serverID) else { return nil }
            let state = pool.state(for: serverID)
            return Row(
                id: serverID,
                name: server.name,
                ownership: ServerStatusText.ownership(of: server),
                status: pendingServerIDs.contains(serverID)
                    ? "Connecting…"
                    : ServerStatusText.label(for: state),
                isEnabled: priority.isEnabled(serverID),
                isConnected: state.isConnected
            )
        }
    }

    /// True until the first connect pass has produced a server list, so the
    /// screen can show a spinner instead of claiming the account has none.
    var isLoading: Bool {
        plexService.pool.servers.isEmpty && !connections.hasCompletedFirstPass
    }

    var isRefreshing: Bool {
        connections.isConnecting
    }

    /// Only an account-level failure (not signed in, plex.tv unreachable). A
    /// single server failing is shown on its own row instead.
    var accountError: String? {
        connections.lastError
    }

    /// One server is the common case and must not look like a power feature:
    /// no ordering affordances, no talk of priority.
    var isSingleServer: Bool {
        rows.count <= 1
    }

    var hasEnabledServer: Bool {
        rows.contains(where: \.isEnabled)
    }

    func position(of serverID: String) -> Int {
        rows.firstIndex { $0.id == serverID } ?? 0
    }

    // MARK: - Loading

    func load() async {
        await connections.connectIfNeeded(session: plexService.activeProfileID)
    }

    /// Explicit retry: re-discovers the account's servers and re-probes every
    /// enabled one.
    func refresh() async {
        await connections.refresh()
    }

    // MARK: - Editing

    /// iOS/iPadOS list editing. The offsets index the visible rows, which is not
    /// the stored order — a server that has gone missing keeps its slot in the
    /// store — so the reordered identifiers are handed back whole.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var identifiers = rows.map(\.id)
        identifiers.move(fromOffsets: offsets, toOffset: destination)
        plexService.serverPriority.reorder(visible: identifiers)
    }

    /// tvOS position menus: move one server to an absolute slot.
    func move(_ serverID: String, to index: Int) {
        var identifiers = rows.map(\.id)
        guard let current = identifiers.firstIndex(of: serverID) else { return }

        let target = min(max(index, 0), identifiers.count - 1)
        guard current != target else { return }

        let moved = identifiers.remove(at: current)
        identifiers.insert(moved, at: target)
        plexService.serverPriority.reorder(visible: identifiers)
    }

    func setEnabled(_ isEnabled: Bool, for serverID: String) {
        plexService.serverPriority.setEnabled(isEnabled, for: serverID)

        guard isEnabled else {
            // Dropping the session is what makes the rest of the app forget the
            // server; the priority flag alone only stops the next connect pass.
            plexService.pool.markDisabled(serverID: serverID)
            return
        }

        pendingServerIDs.insert(serverID)
        Task { [weak self] in
            await self?.connect(serverID)
        }
    }

    private func connect(_ serverID: String) async {
        defer { pendingServerIDs.remove(serverID) }

        do {
            try await plexService.reconnectServer(serverID: serverID)
        } catch {
            // Discovery can fail before the pool ever hears about this server,
            // which would leave the row reading "Disabled" under an on switch.
            if plexService.pool.state(for: serverID) == .disabled {
                plexService.pool.markOffline(
                    serverID: serverID,
                    reason: error.localizedDescription
                )
            }
        }
    }
}
