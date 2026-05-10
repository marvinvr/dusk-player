import Foundation
import Observation

@MainActor
@Observable
final class OfflinePlaybackSyncManager {
    private static let syncAttemptInterval: TimeInterval = 60

    private let plexService: PlexService
    private let store: OfflinePlaybackSyncStore

    private(set) var actions: [OfflinePlaybackSyncAction] = []
    private(set) var isSyncing = false
    @ObservationIgnored private var lastSyncAttemptAt: Date?

    init(
        plexService: PlexService,
        store: OfflinePlaybackSyncStore = OfflinePlaybackSyncStore()
    ) {
        self.plexService = plexService
        self.store = store
        actions = store.loadSnapshot().actions
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
        actions.removeAll()
        persist()
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
        guard let currentServerID = plexService.currentServerIdentifier else { return }

        let pendingActions = actions
            .filter { $0.needsSync && $0.serverID == currentServerID }
            .sorted { $0.updatedAt < $1.updatedAt }
        guard !pendingActions.isEmpty else { return }

        let now = Date()
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
        let globalKey = DownloadedMediaRecord.globalKey(serverID: serverID, ratingKey: ratingKey)
        return actions.first { $0.globalKey == globalKey }
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
        let globalKey = DownloadedMediaRecord.globalKey(serverID: serverID, ratingKey: ratingKey)
        if let index = actions.firstIndex(where: { $0.globalKey == globalKey }) {
            actions[index].kind = kind
            actions[index].viewOffsetMs = viewOffsetMs
            actions[index].durationMs = durationMs
            actions[index].shouldMarkWatched = shouldMarkWatched
            actions[index].plexState = plexState
            actions[index].needsSync = true
            actions[index].updatedAt = .now
        } else {
            actions.append(OfflinePlaybackSyncAction(
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
        guard let index = actions.firstIndex(where: { $0.globalKey == action.globalKey }) else { return }
        guard actions[index].updatedAt == action.updatedAt,
              actions[index].kind == action.kind,
              actions[index].viewOffsetMs == action.viewOffsetMs,
              actions[index].durationMs == action.durationMs,
              actions[index].plexState == action.plexState else {
            return
        }
        actions[index].needsSync = false
        actions[index].attemptCount = 0
        actions[index].lastAttemptAt = .now
        actions[index].updatedAt = .now
        persist()
    }

    private func markAttemptFailed(_ action: OfflinePlaybackSyncAction) {
        guard let index = actions.firstIndex(where: { $0.globalKey == action.globalKey }) else { return }
        actions[index].attemptCount += 1
        actions[index].lastAttemptAt = .now
        actions[index].updatedAt = .now
        persist()
    }

    private func persist() {
        try? store.saveSnapshot(OfflinePlaybackSyncSnapshot(actions: actions))
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
