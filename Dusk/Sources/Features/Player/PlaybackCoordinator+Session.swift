import Foundation

extension PlaybackCoordinator {
    @discardableResult
    func startPlaybackSession(
        ratingKey: String,
        startPositionOverride: TimeInterval?,
        presentPlayer: Bool
    ) async -> Bool {
        loadError = nil
        cancelUpNextCountdown()
        upNextPresentation = nil

        do {
            let details = try await plexService.getMediaDetails(ratingKey: ratingKey)

            guard let media = details.media.first,
                  let part = media.parts.first else {
                loadError = "No playable media found."
                return false
            }

            guard let url = plexService.directPlayURL(for: part) else {
                loadError = "Could not construct playback URL."
                return false
            }

            let engineType = StreamResolver.resolve(
                media: media,
                forceAVPlayer: preferences.forceAVPlayer,
                forceVLCKit: preferences.forceVLCKit
            )

            let newEngine = PlaybackEngineFactory.makeEngine(
                for: media,
                forceAVPlayer: preferences.forceAVPlayer,
                forceVLCKit: preferences.forceVLCKit
            )
            newEngine.onPlaybackEnded = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handlePlaybackEnded()
                }
            }

            hasScrobbled = false
            didFinalizeCurrentSession = false
            lastReportedTimeMs = 0
            lastReportedDurationMs = 0
            self.ratingKey = ratingKey
            activeItemDetails = details
            engine = newEngine
            playbackSource = PlaybackSource(
                url: url,
                startPosition: startPositionOverride ?? details.viewOffset.map { TimeInterval($0) / 1000.0 }
            )
            debugInfo = PlaybackDebugInfo(
                title: details.title,
                engine: engineType,
                decision: .directPlay,
                media: media,
                part: part
            )
            playerPresentationID = UUID()
            startTimelineReporting()

            if presentPlayer {
                showPlayer = true
            }

            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    func handlePlaybackEnded() async {
        guard !isHandlingPlaybackEnded else { return }
        isHandlingPlaybackEnded = true
        defer { isHandlingPlaybackEnded = false }

        if let activeItemDetails,
           activeItemDetails.type == .episode,
           let nextEpisode = try? await plexService.getNextEpisode(after: activeItemDetails) {
            finalizeCurrentPlaybackSession(markCompleted: true)
            presentUpNext(for: nextEpisode)
            return
        }

        finalizeCurrentPlaybackSession(markCompleted: true)
        showPlayer = false
    }

    func finalizeCurrentPlaybackSession(markCompleted: Bool) {
        guard !didFinalizeCurrentSession else { return }
        didFinalizeCurrentSession = true

        timelineTimer?.invalidate()
        timelineTimer = nil

        let snapshot = timelineSnapshot(markCompleted: markCompleted)
        lastReportedTimeMs = snapshot.timeMs
        lastReportedDurationMs = snapshot.durationMs

        if let ratingKey {
            Task {
                await plexService.reportTimeline(
                    ratingKey: ratingKey,
                    state: .stopped,
                    timeMs: snapshot.timeMs,
                    durationMs: snapshot.durationMs
                )
            }

            if !hasScrobbled,
               snapshot.durationMs > 0,
               snapshot.timeMs > Int(Double(snapshot.durationMs) * 0.9) {
                hasScrobbled = true
                Task {
                    try? await plexService.scrobble(ratingKey: ratingKey)
                }
            }
        }

        engine?.onPlaybackEnded = nil
        engine?.stop()
    }

    func timelineSnapshot(markCompleted: Bool) -> (timeMs: Int, durationMs: Int) {
        let engineTimeMs = engine.map { Int($0.currentTime * 1000) } ?? 0
        let engineDurationMs = engine.map { Int($0.duration * 1000) } ?? 0

        let durationMs = max(lastReportedDurationMs, engineDurationMs)
        var timeMs = max(lastReportedTimeMs, engineTimeMs)

        if markCompleted, durationMs > 0 {
            timeMs = durationMs
        } else if durationMs > 0 {
            timeMs = min(timeMs, durationMs)
        }

        return (timeMs, durationMs)
    }

    func clearPlayerState() {
        timelineTimer?.invalidate()
        timelineTimer = nil
        cancelUpNextCountdown()
        upNextPresentation = nil
        engine?.onPlaybackEnded = nil
        engine = nil
        activeItemDetails = nil
        debugInfo = nil
        playbackSource = nil
        ratingKey = nil
        hasScrobbled = false
        didFinalizeCurrentSession = false
        isHandlingPlaybackEnded = false
        lastReportedTimeMs = 0
        lastReportedDurationMs = 0
        continuousPlayEpisodeRunCount = 0
    }
}
