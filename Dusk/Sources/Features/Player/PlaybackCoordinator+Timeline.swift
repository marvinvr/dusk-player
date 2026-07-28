import Foundation
import SwiftUI

extension PlaybackCoordinator {
    func startTimelineReporting() {
        transcodePingTickCounter = 0
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reportCurrentTimeline()
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
        Task {
            await plexService.pingTranscodeSession(transcodeSessionID: transcodeSessionID)
        }
    }

    func reportCurrentTimeline(stateOverride: PlaybackState? = nil) {
        guard let engine, let ratingKey else { return }

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
                // Report "buffering" (see submitTimeline's mapping) instead of
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
            ratingKey: ratingKey,
            state: plexState,
            timeMs: timeMs,
            durationMs: durationMs
        )

        if activeLiveTVContext == nil,
           !hasScrobbled, durationMs > 0, timeMs > Int(Double(durationMs) * 0.9) {
            hasScrobbled = true
            if activePlaybackUsesLocalDownload {
                offlinePlaybackSyncManager?.recordProgress(
                    serverID: activePlaybackServerID,
                    ratingKey: ratingKey,
                    viewOffsetMs: timeMs,
                    durationMs: durationMs,
                    state: plexState
                )
                Task {
                    await offlinePlaybackSyncManager?.syncPendingActions()
                }
            } else {
                Task {
                    try? await plexService.scrobble(ratingKey: ratingKey)
                }
            }
        }
    }

    func reportTimelineOrQueueOfflineSync(
        ratingKey: String,
        state: PlaybackState,
        timeMs: Int,
        durationMs: Int
    ) {
        if activePlaybackUsesLocalDownload {
            offlinePlaybackSyncManager?.recordProgress(
                serverID: activePlaybackServerID,
                ratingKey: ratingKey,
                viewOffsetMs: timeMs,
                durationMs: durationMs,
                state: state
            )
            Task {
                await offlinePlaybackSyncManager?.syncPendingActions()
            }
        } else {
            let sessionIdentifier = activePlaybackSessionIdentifier
            let timelineKey = activeLiveTVContext?.sessionPath
            Task {
                await plexService.reportTimeline(
                    ratingKey: ratingKey,
                    key: timelineKey,
                    state: state,
                    timeMs: timeMs,
                    durationMs: durationMs,
                    sessionIdentifier: sessionIdentifier
                )
            }
        }
    }

    func flushTimelineForScenePhase(_ phase: ScenePhase) {
        guard engine != nil, ratingKey != nil else { return }

        switch phase {
        case .inactive:
            reportCurrentTimeline()
        case .background:
            reportCurrentTimeline()
        case .active:
            engine?.handleReturnToForeground()
        @unknown default:
            break
        }
    }
}
