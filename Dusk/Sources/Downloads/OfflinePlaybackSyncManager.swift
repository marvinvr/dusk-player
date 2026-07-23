import Foundation
import Network
import Observation

@MainActor
@Observable
final class OfflinePlaybackSyncManager {
    private static let syncAttemptInterval: TimeInterval = 60
    private static let retryLoopInterval: Duration = .seconds(60)

    private let plexService: PlexService
    private let store: OfflinePlaybackSyncStore

    private(set) var storedActions: [OfflinePlaybackSyncAction] = []
    private(set) var isSyncing = false
    private(set) var isNetworkAvailable = false
    @ObservationIgnored private var lastSyncAttemptAt: Date?
    @ObservationIgnored private var isPreparingProfileSwitch = false
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private let networkMonitorQueue = DispatchQueue(label: "com.dusk.offlinePlaybackSync.networkMonitor")
    @ObservationIgnored private var retryLoopTask: Task<Void, Never>?

    init(
        plexService: PlexService,
        store: OfflinePlaybackSyncStore = OfflinePlaybackSyncStore()
    ) {
        self.plexService = plexService
        self.store = store
        storedActions = store.loadSnapshot().actions
        startNetworkMonitoring()
    }

    deinit {
        networkMonitor?.cancel()
        retryLoopTask?.cancel()
    }

    var actions: [OfflinePlaybackSyncAction] {
        storedActions.filter { $0.accountProfileID == plexService.activeProfileID }
    }

    var pendingSyncCount: Int {
        actions.filter(\.needsSync).count
    }

    func recordProgress(
        serverID: String?,
        ratingKey: String,
        viewOffsetMs: Int,
        durationMs: Int,
        state: PlaybackState = .stopped
    ) {
        guard let serverID = serverID?.nilIfEmpty else { return }
        let shouldMarkWatched = durationMs > 0 && Double(viewOffsetMs) / Double(durationMs) >= 0.9
        upsertAction(
            serverID: serverID,
            ratingKey: ratingKey,
            kind: .progress,
            viewOffsetMs: viewOffsetMs,
            durationMs: durationMs,
            shouldMarkWatched: shouldMarkWatched,
            plexState: Self.plexStateString(for: state)
        )
    }

    func recordWatchState(serverID: String?, ratingKey: String, watched: Bool) {
        guard let serverID = serverID?.nilIfEmpty else { return }
        upsertAction(
            serverID: serverID,
            ratingKey: ratingKey,
            kind: watched ? .watched : .unwatched,
            viewOffsetMs: nil,
            durationMs: nil,
            shouldMarkWatched: watched,
            plexState: nil
        )
    }

    func deleteAllLocalState() {
        let activeProfileID = plexService.activeProfileID
        storedActions.removeAll { $0.accountProfileID == activeProfileID }
        persist()
    }

    /// Flushes the outgoing profile while its Plex token and server are still
    /// active, then stops retries so a later callback cannot use another
    /// profile's credentials.
    func prepareForProfileSwitch() async {
        isPreparingProfileSwitch = true
        stopAutomaticSync()
        while isSyncing {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        await syncPendingActions(force: true)
    }

    /// Refreshes profile-scoped state after PlexService has installed the new
    /// identity. Legacy adoption must only be requested for the original
    /// pre-Plex-Home account.
    func activateProfile() {
        if plexService.shouldAdoptLegacyProfileData,
           let primaryProfileID = plexService.primaryProfileID?.nilIfEmpty {
            var changed = false
            for index in storedActions.indices where storedActions[index].accountProfileID == nil {
                storedActions[index].accountProfileID = primaryProfileID
                changed = true
            }
            if changed {
                persist()
            }
        }
        lastSyncAttemptAt = nil
        isPreparingProfileSwitch = false
        startAutomaticSync()
    }

    func effectiveViewOffsetMs(serverID: String?, ratingKey: String, fallback: Int?) -> Int? {
        guard let action = action(serverID: serverID, ratingKey: ratingKey),
              action.kind == .progress,
              let viewOffsetMs = action.viewOffsetMs,
              viewOffsetMs > 0 else {
            return fallback
        }
        return viewOffsetMs
    }

    func effectiveWatched(serverID: String?, ratingKey: String, fallback: Bool) -> Bool {
        guard let action = action(serverID: serverID, ratingKey: ratingKey) else {
            return fallback
        }

        switch action.kind {
        case .watched:
            return true
        case .unwatched:
            return false
        case .progress:
            return action.shouldMarkWatched || fallback
        }
    }

    func syncPendingActions(force: Bool = false) async {
        guard !isSyncing else { return }
        guard force || !isPreparingProfileSwitch else { return }
        guard force || isNetworkAvailable else { return }
        guard plexService.isSessionReady else { return }
        guard let activeProfileID = plexService.activeProfileID?.nilIfEmpty else { return }
        guard let currentServerID = plexService.currentServerIdentifier else { return }

        let now = Date()
        let pendingActions = storedActions
            .filter { action in
                action.needsSync &&
                    action.accountProfileID == activeProfileID &&
                    action.serverID == currentServerID &&
                    (force || shouldAttemptSync(action, now: now))
            }
            .sorted { $0.updatedAt < $1.updatedAt }
        guard !pendingActions.isEmpty else { return }

        if !force,
           let lastSyncAttemptAt,
           now.timeIntervalSince(lastSyncAttemptAt) < Self.syncAttemptInterval {
            return
        }
        lastSyncAttemptAt = now

        isSyncing = true
        defer { isSyncing = false }

        for pendingAction in pendingActions {
            do {
                try await sync(pendingAction)
                markSynced(pendingAction)
            } catch {
                markAttemptFailed(pendingAction)
            }
        }
    }

    func startAutomaticSync() {
        retryLoopTask?.cancel()
        retryLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.syncPendingActions()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.retryLoopInterval)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await self.syncPendingActions()
            }
        }
    }

    func stopAutomaticSync() {
        retryLoopTask?.cancel()
        retryLoopTask = nil
    }

    private func sync(_ action: OfflinePlaybackSyncAction) async throws {
        switch action.kind {
        case .progress:
            try await plexService.submitTimeline(
                ratingKey: action.ratingKey,
                state: playbackState(for: action.plexState),
                timeMs: action.viewOffsetMs ?? 0,
                durationMs: action.durationMs ?? 0
            )
            if action.shouldMarkWatched {
                try await plexService.scrobble(ratingKey: action.ratingKey)
            }
        case .watched:
            try await plexService.scrobble(ratingKey: action.ratingKey)
        case .unwatched:
            try await plexService.unscrobble(ratingKey: action.ratingKey)
        }
    }

    private func action(serverID: String?, ratingKey: String) -> OfflinePlaybackSyncAction? {
        guard let serverID = serverID?.nilIfEmpty else { return nil }
        let globalKey = DownloadedMediaRecord.globalKey(
            accountProfileID: plexService.activeProfileID,
            serverID: serverID,
            ratingKey: ratingKey
        )
        return storedActions.first { $0.globalKey == globalKey }
    }

    private func upsertAction(
        serverID: String,
        ratingKey: String,
        kind: OfflinePlaybackSyncActionKind,
        viewOffsetMs: Int?,
        durationMs: Int?,
        shouldMarkWatched: Bool,
        plexState: String?
    ) {
        guard !isPreparingProfileSwitch,
              plexService.isSessionReady,
              let activeProfileID = plexService.activeProfileID?.nilIfEmpty else {
            return
        }
        let globalKey = DownloadedMediaRecord.globalKey(
            accountProfileID: activeProfileID,
            serverID: serverID,
            ratingKey: ratingKey
        )
        if let index = storedActions.firstIndex(where: { $0.globalKey == globalKey }) {
            storedActions[index].kind = kind
            storedActions[index].viewOffsetMs = viewOffsetMs
            storedActions[index].durationMs = durationMs
            storedActions[index].shouldMarkWatched = shouldMarkWatched
            storedActions[index].plexState = plexState
            storedActions[index].needsSync = true
            storedActions[index].updatedAt = .now
        } else {
            storedActions.append(OfflinePlaybackSyncAction(
                accountProfileID: activeProfileID,
                serverID: serverID,
                ratingKey: ratingKey,
                kind: kind,
                viewOffsetMs: viewOffsetMs,
                durationMs: durationMs,
                shouldMarkWatched: shouldMarkWatched,
                plexState: plexState,
                needsSync: true,
                attemptCount: 0,
                lastAttemptAt: nil,
                createdAt: .now,
                updatedAt: .now
            ))
        }
        persist()
    }

    private func markSynced(_ action: OfflinePlaybackSyncAction) {
        guard action.accountProfileID == plexService.activeProfileID,
              let index = storedActions.firstIndex(where: { $0.globalKey == action.globalKey }) else {
            return
        }
        guard storedActions[index].updatedAt == action.updatedAt,
              storedActions[index].kind == action.kind,
              storedActions[index].viewOffsetMs == action.viewOffsetMs,
              storedActions[index].durationMs == action.durationMs,
              storedActions[index].plexState == action.plexState else {
            return
        }
        storedActions[index].needsSync = false
        storedActions[index].attemptCount = 0
        storedActions[index].lastAttemptAt = .now
        storedActions[index].updatedAt = .now
        persist()
    }

    private func markAttemptFailed(_ action: OfflinePlaybackSyncAction) {
        guard action.accountProfileID == plexService.activeProfileID,
              let index = storedActions.firstIndex(where: { $0.globalKey == action.globalKey }) else {
            return
        }
        storedActions[index].attemptCount += 1
        storedActions[index].lastAttemptAt = .now
        storedActions[index].updatedAt = .now
        persist()
    }

    private func persist() {
        try? store.saveSnapshot(OfflinePlaybackSyncSnapshot(actions: storedActions))
    }

    private func shouldAttemptSync(_ action: OfflinePlaybackSyncAction, now: Date) -> Bool {
        guard let lastAttemptAt = action.lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= retryDelay(for: action.attemptCount)
    }

    private func retryDelay(for attemptCount: Int) -> TimeInterval {
        switch attemptCount {
        case ...0:
            return 0
        case 1:
            return 60
        case 2:
            return 120
        case 3:
            return 300
        default:
            return 900
        }
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(path)
            }
        }
        monitor.start(queue: networkMonitorQueue)
        networkMonitor = monitor
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = path.status == .satisfied

        if !wasAvailable && isNetworkAvailable {
            Task { @MainActor [weak self] in
                await self?.syncPendingActions()
            }
        }
    }

    private func playbackState(for value: String?) -> PlaybackState {
        switch value {
        case "playing":
            return .playing
        case "paused":
            return .paused
        default:
            return .stopped
        }
    }

    private static func plexStateString(for state: PlaybackState) -> String {
        switch state {
        case .playing:
            return "playing"
        case .paused:
            return "paused"
        default:
            return "stopped"
        }
    }
}
