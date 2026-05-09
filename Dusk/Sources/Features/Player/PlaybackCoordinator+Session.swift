import Foundation
import OSLog

private let playbackSessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlaybackSession"
)

extension PlaybackCoordinator {
    @discardableResult
    func startPlaybackSession(
        ratingKey: String,
        startPositionOverride: TimeInterval?,
        selectedMediaID: Int?,
        presentPlayer: Bool
    ) async -> Bool {
        loadError = nil
        cancelUpNextCountdown()
        upNextPresentation = nil

        do {
            let details: PlexMediaDetails
            if downloadManager?.isPlayableOffline(ratingKey: ratingKey) == true,
               let cachedDetails = downloadManager?.cachedMediaDetails(ratingKey: ratingKey) {
                details = cachedDetails
            } else {
                do {
                    details = try await plexService.getMediaDetails(ratingKey: ratingKey)
                } catch {
                    if let cachedDetails = downloadManager?.cachedMediaDetails(ratingKey: ratingKey) {
                        details = cachedDetails
                    } else {
                        throw error
                    }
                }
            }
            let attemptID = UUID()

            guard let media = resolveMediaVersion(
                    in: details,
                    selectedMediaID: selectedMediaID
                  ),
                  let part = media.parts.first else {
                playbackSessionLogger.error(
                    "Playback attempt failed before engine selection for ratingKey \(ratingKey, privacy: .public): no playable media version was available"
                )
                loadError = "No playable media found."
                return false
            }

            let playbackURL: URL
            let sanitizedURL: String
            let playbackDecision: PlaybackDecision
            let usesLocalDownload: Bool
            if let localURL = downloadManager?.localPlaybackURL(
                for: ratingKey,
                selectedMediaID: selectedMediaID
            ) {
                playbackURL = localURL
                sanitizedURL = localURL.path
                playbackDecision = .localDownload
                usesLocalDownload = true
            } else {
                guard let directPlayURL = plexService.directPlayURL(for: part) else {
                    playbackSessionLogger.error(
                        "Playback attempt failed before engine selection for ratingKey \(ratingKey, privacy: .public): could not construct direct play URL for media \(media.id, privacy: .public), part \(part.id, privacy: .public)"
                    )
                    loadError = "Could not construct playback URL."
                    return false
                }
                playbackURL = directPlayURL
                sanitizedURL = plexService.sanitizedPlaybackURLString(for: directPlayURL)
                playbackDecision = .directPlay
                usesLocalDownload = false
            }

            let resolverDecision = StreamResolver.evaluate(
                media: media,
                forceAVPlayer: preferences.forceAVPlayer,
                forceVLCKit: preferences.forceVLCKit
            )
            let engineType = resolverDecision.engine
            let serverID = downloadManager?.serverID(for: ratingKey) ?? plexService.currentServerIdentifier
            let effectiveViewOffset = usesLocalDownload
                ? offlinePlaybackSyncManager?.effectiveViewOffsetMs(
                    serverID: serverID,
                    ratingKey: ratingKey,
                    fallback: details.viewOffset
                  )
                : details.viewOffset
            let startPosition = startPositionOverride ?? effectiveViewOffset.map { TimeInterval($0) / 1000.0 }
            let attemptContext = PlaybackAttemptContext(
                attemptID: attemptID,
                title: details.title,
                ratingKey: ratingKey,
                engine: engineType,
                resolverReason: resolverDecision.reason,
                mediaID: media.id,
                partID: part.id,
                sanitizedDirectPlayURL: sanitizedURL
            )

            playbackSessionLogger.notice(
                "Playback attempt \(attemptContext.attemptLabel, privacy: .public) prepared for ratingKey \(ratingKey, privacy: .public), title \(details.title, privacy: .public), engine \(String(describing: engineType), privacy: .public), media \(media.id, privacy: .public), part \(part.id, privacy: .public), startPosition=\(String(describing: startPosition), privacy: .public), reason \(resolverDecision.reason, privacy: .public), URL \(sanitizedURL, privacy: .public)"
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
            activePlaybackServerID = serverID
            activePlaybackUsesLocalDownload = usesLocalDownload
            activeItemDetails = details
            engine = newEngine
            playbackSource = PlaybackSource(
                url: playbackURL,
                startPosition: startPosition,
                context: attemptContext
            )
            debugInfo = PlaybackDebugInfo(
                title: details.title,
                engine: engineType,
                decision: playbackDecision,
                media: media,
                part: part,
                attemptID: attemptID,
                resolverReason: resolverDecision.reason,
                sanitizedDirectPlayURL: sanitizedURL
            )
            playerPresentationID = UUID()
            nowPlayingController.beginSession(
                details: details,
                engine: newEngine,
                plexService: plexService,
                skipBackwardInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
                skipForwardInterval: preferences.playerDoubleTapForwardInterval.timeInterval
            )
            startTimelineReporting()

            if presentPlayer {
                showPlayer = true
            }

            return true
        } catch {
            playbackSessionLogger.error(
                "Playback attempt failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            loadError = error.localizedDescription
            return false
        }
    }

    func handlePlaybackEnded() async {
        guard !isHandlingPlaybackEnded else { return }
        guard upNextPresentation == nil else { return }
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
            reportTimelineOrQueueOfflineSync(
                ratingKey: ratingKey,
                state: .stopped,
                timeMs: snapshot.timeMs,
                durationMs: snapshot.durationMs
            )

            if !hasScrobbled,
               snapshot.durationMs > 0,
               snapshot.timeMs > Int(Double(snapshot.durationMs) * 0.9) {
                hasScrobbled = true
                if activePlaybackUsesLocalDownload {
                    offlinePlaybackSyncManager?.recordProgress(
                        serverID: activePlaybackServerID,
                        ratingKey: ratingKey,
                        viewOffsetMs: snapshot.timeMs,
                        durationMs: snapshot.durationMs,
                        state: .stopped
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

        engine?.onPlaybackEnded = nil
        if let engine {
            nowPlayingController.updatePlaybackState(
                state: .stopped,
                currentTime: snapshot.timeMs > 0 ? TimeInterval(snapshot.timeMs) / 1000.0 : engine.currentTime,
                duration: snapshot.durationMs > 0 ? TimeInterval(snapshot.durationMs) / 1000.0 : engine.duration,
                force: true
            )
            engine.stop()
        }
        nowPlayingController.endSession()
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
        nowPlayingController.endSession()
        engine = nil
        activeItemDetails = nil
        activePlaybackServerID = nil
        activePlaybackUsesLocalDownload = false
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

    private func resolveMediaVersion(
        in details: PlexMediaDetails,
        selectedMediaID: Int?
    ) -> PlexMedia? {
        if let selectedMediaID {
            return details.media.first { media in
                media.id == selectedMediaID && !media.parts.isEmpty
            }
        }

        return StreamResolver.selectMediaVersion(
            from: details.media,
            preferredMaxResolution: preferences.maxResolution
        )
    }
}
