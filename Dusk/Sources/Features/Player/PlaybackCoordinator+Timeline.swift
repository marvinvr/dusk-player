import Foundation
import SwiftUI

extension PlaybackCoordinator {
    func startTimelineReporting() {
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reportCurrentTimeline()
            }
        }
    }

    func reportCurrentTimeline(stateOverride: PlaybackState? = nil) {
        guard let engine, let ratingKey else { return }

        let timeMs = Int(engine.currentTime * 1000)
        let durationMs = Int(engine.duration * 1000)

        lastReportedTimeMs = timeMs
        lastReportedDurationMs = durationMs

        let plexState: PlaybackState
        if let stateOverride {
            plexState = stateOverride
        } else {
            switch engine.state {
            case .playing: plexState = .playing
            case .paused: plexState = .paused
            default: return
            }
        }

        Task {
            await plexService.reportTimeline(
                ratingKey: ratingKey,
                state: plexState,
                timeMs: timeMs,
                durationMs: durationMs
            )
        }

        if !hasScrobbled, durationMs > 0, timeMs > Int(Double(durationMs) * 0.9) {
            hasScrobbled = true
            Task {
                try? await plexService.scrobble(ratingKey: ratingKey)
            }
        }
    }

    func flushTimelineForScenePhase(_ phase: ScenePhase) {
        guard engine != nil, ratingKey != nil else { return }

        switch phase {
        case .inactive:
            reportCurrentTimeline(
                stateOverride: engine?.state == .playing ? .paused : nil
            )
        case .background:
            if engine?.state == .playing {
                engine?.pause()
            }
            reportCurrentTimeline(stateOverride: .paused)
        case .active:
            break
        @unknown default:
            break
        }
    }
}
