import Foundation
import SwiftUI

extension PlaybackCoordinator {
    func startTimelineReporting() {
        transcodePingTickCounter = 0
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reportCurrentTimeline()
                self?.saveIPTVResumePointIfDue()
                self?.pingActiveTranscodeSessionIfNeeded()
            }
        }
    }

    /// Keep-alive for the server transcoder: Plex reaps transcode sessions it
    /// has not heard from, so while one is active ping it roughly every 60
    /// seconds (every 6th 10-second timeline tick).
    func pingActiveTranscodeSessionIfNeeded() {
        guard let transcodeSessionID = activeTranscodeSessionID else {
            transcodePingTickCounter = 0
            return
        }

        transcodePingTickCounter += 1
        guard transcodePingTickCounter >= 6 else { return }
        transcodePingTickCounter = 0
        let serverID = activePlaybackServerID
        Task {
            await media.pingTranscodeSession(
                transcodeSessionID: transcodeSessionID,
                serverID: serverID
            )
        }
    }

    func reportCurrentTimeline(stateOverride: PlaybackState? = nil) {
        guard let engine, let itemID else { return }

        nowPlayingController.updatePlaybackState(
            state: engine.state,
            currentTime: engine.currentTime,
            duration: engine.duration
        )

        let plexState: PlaybackState
        if let stateOverride {
            plexState = stateOverride
        } else {
            switch engine.state {
            case .playing: plexState = .playing
            case .paused: plexState = .paused
            case .loading:
                // Report "buffering" (`PlaybackReport.State.buffering`) instead of
                // dropping the tick, so Plex keeps the session and any server
                // transcoder alive while the engine opens or refills. Local
                // downloads keep the old drop behavior: their ticks feed the
                // offline sync manager, which has no buffering concept.
                guard !activePlaybackUsesLocalDownload else { return }
                plexState = .loading
            default: return
            }
        }

        // A loading/buffering engine can report time 0; keep the last known
        // position instead of regressing the server's view of progress.
        let isBufferingReport = plexState == .loading
        let timeMs = isBufferingReport
            ? max(lastReportedTimeMs, Int(engine.currentTime * 1000))
            : Int(engine.currentTime * 1000)
        let durationMs = isBufferingReport
            ? max(lastReportedDurationMs, Int(engine.duration * 1000))
            : Int(engine.duration * 1000)

        lastReportedTimeMs = timeMs
        lastReportedDurationMs = durationMs

        reportTimelineOrQueueOfflineSync(
            itemID: itemID,
            state: plexState,
            timeMs: timeMs,
            durationMs: durationMs
        )

        if activeLiveTVContext == nil, !isPlayingIPTVCatchUp,
           !hasScrobbled, durationMs > 0, timeMs > Int(Double(durationMs) * 0.9) {
            hasScrobbled = true
            recordFinishedPlayback(
                itemID: itemID,
                timeMs: timeMs,
                durationMs: durationMs,
                state: plexState
            )
        }
    }

    /// Dusk's 90 % rule fired: the item is finished. Hands it to Trakt and
    /// marks it watched — in the offline queue for a local download, otherwise
    /// on the server the session plays from, unless that server marks it
    /// played itself from the stopped report
    /// (`PlaybackTraits.serverAppliesWatchedThreshold`), where a second write
    /// would count the play twice. The caller sets `hasScrobbled`.
    func recordFinishedPlayback(
        itemID: String,
        timeMs: Int,
        durationMs: Int,
        state: PlaybackState
    ) {
        reportFinishedToTrakt()
        if activePlaybackUsesLocalDownload {
            offlinePlaybackSyncManager?.recordProgress(
                serverID: activePlaybackServerID,
                itemID: itemID,
                viewOffsetMs: timeMs,
                durationMs: durationMs,
                state: state
            )
            Task {
                await offlinePlaybackSyncManager?.syncPendingActions()
            }
        } else {
            let serverID = activePlaybackServerID
            guard !media.serverAppliesWatchedThreshold(serverID: serverID) else { return }
            Task {
                try? await media.setWatched(true, itemID: itemID, serverID: serverID)
            }
        }
    }

    /// Hands a scrobbled movie/episode to Trakt (when linked). Fire and forget:
    /// `TraktService` only queues, so playback never waits on or sees Trakt.
    func reportFinishedToTrakt() {
        guard let traktService, let details = activeItemDetails, details.itemID == itemID else { return }
        traktService.recordFinished(type: details.type, guid: details.guid, externalIDs: details.externalIDs)
    }

    func reportTimelineOrQueueOfflineSync(
        itemID: String,
        state: PlaybackState,
        timeMs: Int,
        durationMs: Int
    ) {
        // IPTV is not a server session: no report, no offline sync. Without
        // this its nil server ID would route the report to the primary server.
        guard activeLiveTVContext?.isIPTV != true, !isPlayingIPTVCatchUp else { return }
        if activePlaybackUsesLocalDownload {
            offlinePlaybackSyncManager?.recordProgress(
                serverID: activePlaybackServerID,
                itemID: itemID,
                viewOffsetMs: timeMs,
                durationMs: durationMs,
                state: state
            )
            Task {
                await offlinePlaybackSyncManager?.syncPendingActions()
            }
        } else {
            // Only the server this session plays from: the same item id is a
            // different title everywhere else, so a fan-out would corrupt watch
            // state on every other server.
            let report = PlaybackReport(
                item: MediaItemID(serverID: activePlaybackServerID, itemID: itemID),
                state: PlaybackReport.State(state),
                positionMs: timeMs,
                durationMs: durationMs,
                sessionID: activePlaybackSessionIdentifier,
                liveSessionPath: activeLiveTVContext?.sessionPath
            )
            Task {
                await media.report(report)
            }
        }
    }

    func flushTimelineForScenePhase(_ phase: ScenePhase) {
        guard engine != nil, itemID != nil else { return }

        switch phase {
        case .inactive:
            reportCurrentTimeline()
            saveIPTVResumePoint()
        case .background:
            playerSceneWasBackgrounded = true
            reportCurrentTimeline()
            saveIPTVResumePoint()
        case .active:
            // Control Center, Notification Center, a system alert or the app
            // switcher peek only make the scene inactive: nothing was torn
            // down, and the refresh (AVPlayer detaches its layer and seeks)
            // would briefly make Picture in Picture impossible — an
            // immediate swipe home then started no PiP.
            guard playerSceneWasBackgrounded else { return }
            playerSceneWasBackgrounded = false
            engine?.handleReturnToForeground()
        @unknown default:
            break
        }
    }
}
