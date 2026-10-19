import Foundation
import OSLog

private let prerollLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "Prerolls"
)

/// The server's pre-roll videos, playing in front of a movie.
///
/// Pre-rolls are a phase *before* the movie's session, not part of it: they
/// play straight from their part URL, never report a timeline, never scrobble
/// and never touch resume state, so watch state only ever lands on the movie.
/// Once the last one ends (or is skipped) the movie starts through the normal
/// `runPlaybackAttempt` with the very request the viewer made.
struct PrerollPlayback {
    /// The movie request the pre-rolls stand in front of, replayed verbatim
    /// once they are done.
    struct Feature {
        let id: PlexItemID
        let startPositionOverride: TimeInterval?
        let resumeOffsetMilliseconds: Int?
        let resumeOffsetDurationMilliseconds: Int?
        let selectedMediaID: Int?
        let restrictToItemServer: Bool
    }

    struct Item {
        let details: PlexMediaDetails
        let media: PlexMedia
        let part: PlexMediaPart
        let url: URL
        let engineType: PlaybackEngineType
    }

    let items: [Item]
    let serverID: String?
    let feature: Feature
    var index = 0

    var current: Item { items[index] }
    var isLast: Bool { index == items.index(before: items.endIndex) }
}

extension PlaybackCoordinator {
    /// Starts the server's pre-rolls for `details` when it has any, and
    /// returns whether it did. On false the caller carries on with the movie;
    /// it must still check that its attempt was not superseded meanwhile.
    ///
    /// Like official Plex clients, only a movie started from the beginning
    /// gets them: resuming mid-movie, downloads, AirPlay and SharePlay go
    /// straight to the movie (the caller filters the first three).
    func startPrerollsIfConfigured(
        for details: PlexMediaDetails,
        serverID: String?,
        feature: PrerollPlayback.Feature,
        attemptID: UUID
    ) async -> Bool {
        // Videos libraries are `movie` + `subtype == "clip"`; those are not films.
        guard details.type == .movie, details.subtype != "clip", !isSharePlayActive else { return false }

        let profileSession = plexService.serverSessionToken
        let queue: [PlexMediaDetails]
        do {
            queue = try await plexService.cinemaPrerolls(forMovieRatingKey: details.ratingKey, serverID: serverID)
        } catch {
            // Pre-rolls are never worth failing (or delaying) the movie over.
            prerollLogger.notice(
                "Pre-roll lookup failed for ratingKey \(details.ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        guard !Task.isCancelled,
              currentPlaybackAttemptID == attemptID,
              profileSession == plexService.serverSessionToken else { return false }

        let items = queue.compactMap { prerollItem(for: $0, serverID: serverID) }
        guard !items.isEmpty else { return false }

        prerollLogger.notice(
            "Playing \(items.count, privacy: .public) pre-roll(s) before ratingKey \(details.ratingKey, privacy: .public)"
        )
        prerollPlayback = PrerollPlayback(items: items, serverID: serverID, feature: feature)
        startCurrentPreroll()
        return true
    }

    /// Ends the pre-roll on screen and moves on: to the next one, or to the
    /// movie after the last. `presentationID` pins the call to the pre-roll it
    /// was made for, so an end-of-file callback racing a Skip or an error
    /// cannot skip two at once.
    func advancePreroll(from presentationID: UUID) {
        guard var preroll = prerollPlayback, playerPresentationID == presentationID else { return }

        stopPrerollEngine()
        if preroll.isLast {
            Task { await startFeatureAfterPrerolls(preroll.feature) }
        } else {
            preroll.index += 1
            prerollPlayback = preroll
            startCurrentPreroll()
        }
    }

    private func prerollItem(for details: PlexMediaDetails, serverID: String?) -> PrerollPlayback.Item? {
        guard let media = StreamResolver.selectMediaVersion(
                from: details.media,
                preferredMaxResolution: preferences.maxResolution
              ) ?? details.media.first,
              let part = media.firstAvailablePart,
              let url = plexService.directPlayURL(for: part, serverID: serverID) else {
            prerollLogger.error("Skipping pre-roll ratingKey \(details.ratingKey, privacy: .public): no playable part")
            return nil
        }
        let engineType = StreamResolver.evaluate(
            media: media,
            forceAVPlayer: preferences.forceAVPlayer,
            forceVLCKit: preferences.forceVLCKit
        ).engine
        return PrerollPlayback.Item(details: details, media: media, part: part, url: url, engineType: engineType)
    }

    private func startCurrentPreroll() {
        guard let preroll = prerollPlayback else { return }
        let item = preroll.current
        let presentationID = UUID()

        let newEngine = PlaybackEngineFactory.makeEngine(type: item.engineType)
        newEngine.configureVideoEnhancement(.disabled)
        newEngine.onPlaybackEnded = { [weak self] in
            Task { @MainActor [weak self] in
                self?.advancePreroll(from: presentationID)
            }
        }

        // No `ratingKey`: that is what keeps the timeline, scrobble and
        // scene-phase reporting away from the pre-roll.
        ratingKey = nil
        activeItemDetails = nil
        debugInfo = nil
        didFinalizeCurrentSession = false
        activePlaybackServerID = preroll.serverID
        engine = newEngine
        playbackSource = PlaybackSource(
            url: item.url,
            startPosition: nil,
            context: PlaybackAttemptContext(
                attemptID: currentPlaybackAttemptID ?? UUID(),
                title: item.details.title,
                ratingKey: item.details.ratingKey,
                engine: item.engineType,
                resolverReason: "Plex pre-roll",
                mediaID: item.media.id,
                partID: item.part.id,
                sanitizedPlaybackURL: plexService.sanitizedPlaybackURLString(for: item.url)
            ),
            locality: sourceLocality(for: item.url, serverID: preroll.serverID)
        )
        playerPresentationID = presentationID
        nowPlayingController.beginSession(
            details: item.details,
            engine: newEngine,
            plexService: plexService,
            skipBackwardInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
            skipForwardInterval: preferences.playerDoubleTapForwardInterval.timeInterval
        )
    }

    /// Stops the pre-roll engine without the session finalize: there is no
    /// timeline to close, and the audio session stays up for what follows.
    private func stopPrerollEngine() {
        engine?.onPlaybackEnded = nil
        engine?.stop()
        didFinalizeCurrentSession = true
        noteActivePlaybackState(.stopped)
    }

    private func startFeatureAfterPrerolls(_ feature: PrerollPlayback.Feature) async {
        // Back to the movie's loading placeholder while its session prepares.
        prerollPlayback = nil
        engine = nil
        playbackSource = nil

        let attemptID = UUID()
        currentPlaybackAttemptID = attemptID
        let didStart = await runPlaybackAttempt(
            id: feature.id,
            startPositionOverride: feature.startPositionOverride,
            resumeOffsetMilliseconds: feature.resumeOffsetMilliseconds,
            resumeOffsetDurationMilliseconds: feature.resumeOffsetDurationMilliseconds,
            selectedMediaID: feature.selectedMediaID,
            restrictToItemServer: feature.restrictToItemServer,
            attemptID: attemptID
        )
        guard currentPlaybackAttemptID == attemptID else { return }
        if didStart {
            resetContinuousPlayEpisodeRunCountForCurrentItem()
        } else {
            continuousPlayEpisodeRunCount = 0
        }
    }
}
