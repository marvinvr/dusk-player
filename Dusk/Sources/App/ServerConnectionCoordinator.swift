import Foundation
import Network
import Observation

/// Keeps the server pool connected while the app runs.
///
/// The tab shell mounts as soon as the Plex session is ready and this connects
/// underneath it, so a slow or unreachable server can never hold up the UI —
/// each server appears as soon as it answers. A pass runs on the first mount,
/// on a profile switch, when the app returns to the foreground, and when the
/// network path changes: the same moments the single-server build used to
/// re-probe its one connection.
///
/// Only one pass is ever in flight; concurrent callers join the running one.
@MainActor
@Observable
final class ServerConnectionCoordinator {
    /// How long a finished pass stays fresh. Foregrounding inside this window
    /// is ignored so switching apps for a moment does not re-probe everything.
    private static let refreshInterval: TimeInterval = 60

    private(set) var isConnecting = false
    /// Set only when the *account* could not be used (not signed in, discovery
    /// failed). A single server failing is not an error here — it lives in
    /// `ServerPool.states` and is shown per row.
    private(set) var lastError: String?
    /// False until the first pass finishes, so screens can tell "still starting
    /// up" from "tried and found nothing".
    private(set) var hasCompletedFirstPass = false

    @ObservationIgnored private var plexService: PlexService?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var lastPassFinishedAt: Date?
    /// The running pass and the session it belongs to. A pass is only ever
    /// joined by callers of the *same* session: joining one from a previous
    /// Plex Home member would re-register that member's servers.
    @ObservationIgnored private var activePass: Task<String?, Never>?
    @ObservationIgnored private var activePassSession: String?
    /// Set when a retry arrives while a pass is already probing. That pass was
    /// started before the reason for the retry existed, so joining it is not an
    /// answer — another pass runs behind it.
    @ObservationIgnored private var needsAnotherPass = false

    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var hasObservedNetworkPath = false
    @ObservationIgnored private var isNetworkAvailable = true
    @ObservationIgnored private var networkInterfaces: Set<String> = []
    @ObservationIgnored private let networkMonitorQueue = DispatchQueue(
        label: "app.dusk.server-connection-coordinator.network"
    )

    deinit {
        networkMonitor?.cancel()
    }

    // MARK: - Lifecycle

    /// Binds the coordinator to the service and starts watching the network.
    /// Idempotent: the shell calls it every time the session context changes.
    func start(plexService: PlexService) {
        self.plexService = plexService
        guard networkMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(path)
            }
        }
        monitor.start(queue: networkMonitorQueue)
        networkMonitor = monitor
    }

    /// Connects when there is something to gain: the first pass, a new profile,
    /// a stale pass, or a pool that currently has nothing usable. `session` is
    /// the active profile identifier; a change to it forgets the old pass.
    func connectIfNeeded(session: String?) async {
        if session != sessionID {
            sessionID = session
            lastPassFinishedAt = nil
            hasCompletedFirstPass = false
            lastError = nil
            // Whatever is still probing belongs to the profile we just left.
            cancelActivePass()
        }

        guard isStale else {
            await joinActivePass()
            return
        }
        await connect()
    }

    /// A user-initiated retry: always re-probes, even if the last pass is fresh
    /// and even if one is already running.
    func refresh() async {
        lastPassFinishedAt = nil
        if activePass != nil, activePassSession == sessionID {
            needsAnotherPass = true
        }
        await connect()
    }

    /// Foreground: worth a pass only when the last one has gone stale or left
    /// the pool without a usable server.
    func applicationDidBecomeActive() {
        Task { await connectIfNeeded(session: sessionID) }
    }

    // MARK: - Connecting

    private func connect() async {
        if let running = activePass, activePassSession == sessionID {
            _ = await running.value
            // The pass that just finished answers this caller unless a retry
            // arrived while it was running.
            guard needsAnotherPass else { return }
        }

        guard let plexService, plexService.isSessionReady else { return }

        needsAnotherPass = false
        let session = sessionID
        isConnecting = true
        let pass = Task { () -> String? in
            do {
                try await plexService.connectAllServers()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        activePass = pass
        activePassSession = session
        let failure = await pass.value

        // A profile switch, a sign-out, or a retry queued behind this pass has
        // already retired it; whoever replaced it owns the outcome.
        guard activePass == pass else { return }
        activePass = nil
        activePassSession = nil
        lastError = failure
        lastPassFinishedAt = .now
        hasCompletedFirstPass = true
        isConnecting = false
    }

    /// Waits for the running pass, but only when it belongs to this session.
    private func joinActivePass() async {
        guard let activePass, activePassSession == sessionID else { return }
        _ = await activePass.value
    }

    private func cancelActivePass() {
        activePass?.cancel()
        activePass = nil
        activePassSession = nil
        needsAnotherPass = false
        isConnecting = false
    }

    private var isStale: Bool {
        guard let plexService, plexService.isSessionReady else { return false }
        guard hasCompletedFirstPass, let lastPassFinishedAt else { return true }
        // Nothing usable is always worth another try, however recent the pass.
        guard plexService.pool.availability.isReady else { return true }
        return Date().timeIntervalSince(lastPassFinishedAt) >= Self.refreshInterval
    }

    // MARK: - Network

    /// A network change usually means a different endpoint now wins (leaving
    /// the house, joining Wi-Fi), so it forces a pass rather than merely
    /// allowing one. The monitor's first callback only records the baseline.
    private func handleNetworkPathUpdate(_ path: NWPath) {
        let isAvailable = path.status == .satisfied
        let interfaces = Set(path.availableInterfaces.map(\.name))
        let wasAvailable = isNetworkAvailable
        let previousInterfaces = networkInterfaces

        isNetworkAvailable = isAvailable
        networkInterfaces = interfaces

        guard hasObservedNetworkPath else {
            hasObservedNetworkPath = true
            return
        }
        guard isAvailable, !wasAvailable || interfaces != previousInterfaces else { return }

        Task { await refresh() }
    }
}
