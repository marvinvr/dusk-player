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
        resumeOffsetMilliseconds: Int?,
        selectedMediaID: Int?,
        attemptID: UUID
    ) async -> Bool {
        loadError = nil
        qualitySwitchError = nil
        cancelUpNextCountdown()
        cancelDirectPlayFallbackWatch()
        // Any Up Next overlay stays visible as the loading state for the next
        // episode; it's cleared when the new engine commits below.
        // Plex session hygiene: a replaced session that was never finalized
        // (e.g. direct restart) must not leave its server transcoder running.
        if let staleTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(staleTranscodeSessionID)
            activeTranscodeSessionID = nil
        }

        do {
            let details: PlexMediaDetails
            if downloadManager?.isPlayableOffline(ratingKey: ratingKey) == true,
               let cachedDetails = downloadManager?.cachedMediaDetails(ratingKey: ratingKey) {
                details = cachedDetails
            } else {
                do {
                    details = try await plexService.getMediaDetails(ratingKey: ratingKey, checkFiles: true)
                } catch {
                    if let cachedDetails = downloadManager?.cachedMediaDetails(ratingKey: ratingKey) {
                        details = cachedDetails
                    } else {
                        throw error
                    }
                }
            }

            // A newer attempt or a dismissal can supersede this one during the
            // metadata fetch; bail before building any playback state.
            guard currentPlaybackAttemptID == attemptID else { return false }

            airPlayController.refreshRoute(notify: false)
            let wantsAirPlay = airPlayController.isAirPlayRouteSelected
            let downloadedURL = downloadManager?.localPlaybackURL(
                for: ratingKey,
                selectedMediaID: selectedMediaID
            )
            // AirPlay receivers cannot consume Dusk's private app-container URL.
            // When the matching Plex server is reachable, ask it for HLS even if
            // this item also has a completed local download.
            let localURL = wantsAirPlay ? nil : downloadedURL
            let localMediaVersion = localURL.flatMap { _ in
                downloadManager?.downloadedMediaVersion(
                    for: ratingKey,
                    in: details,
                    selectedMediaID: selectedMediaID
                )
            }
            if localURL != nil && localMediaVersion == nil {
                playbackSessionLogger.error(
                    "Playback attempt failed before engine selection for ratingKey \(ratingKey, privacy: .public): local download metadata did not match the downloaded media version"
                )
                loadError = "Downloaded file metadata is incomplete. Retry the download."
                return false
            }
            let media = localMediaVersion?.media ?? resolveMediaVersion(
                in: details,
                selectedMediaID: selectedMediaID
            )
            let part = localMediaVersion?.part ?? media?.firstAvailablePart

            guard let media,
                  let part else {
                playbackSessionLogger.error(
                    "Playback attempt failed before engine selection for ratingKey \(ratingKey, privacy: .public): no playable media version was available"
                )
                loadError = "No playable media found."
                return false
            }

            let resolverDecision = StreamResolver.evaluate(
                media: media,
                forceAVPlayer: preferences.forceAVPlayer,
                forceVLCKit: preferences.forceVLCKit
            )

            let sessionIdentifier = UUID().uuidString
            var playbackURL: URL
            var sanitizedURL: String
            var playbackDecision: PlaybackDecision
            let usesLocalDownload: Bool
            var engineType = resolverDecision.engine
            var resolverReason = resolverDecision.reason
            var transcodeSessionID: String?

            if let localURL {
                playbackURL = localURL
                sanitizedURL = localURL.path
                playbackDecision = .localDownload
                usesLocalDownload = true
            } else {
                if wantsAirPlay, !plexService.isConnected {
                    loadError = "Connect to the matching Plex server to AirPlay this item."
                    return false
                }
                // Plex Pass gate: away from the server's LAN, remote playback of
                // personal media needs an entitlement. Surface a clear message
                // instead of letting the stream fail slowly. Only fires for owned
                // servers we positively know lack a subscription; offline
                // downloads reached the branch above and are never gated.
                if let restriction = await plexService.remoteStreamingRestriction() {
                    guard currentPlaybackAttemptID == attemptID else { return false }
                    playbackSessionLogger.notice(
                        "Blocking remote playback for ratingKey \(ratingKey, privacy: .public): \(String(describing: restriction), privacy: .public)"
                    )
                    loadError = restriction.message
                    return false
                }

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

                if wantsAirPlay {
                    let mediaIndex = details.media.firstIndex { $0.id == media.id } ?? 0
                    let airPlaySessionID = UUID().uuidString
                    let audioStreamID = PlayerViewModel.preferredAudioStreamID(
                        inPart: part,
                        preferredLanguage: preferences.defaultAudioLanguage
                    )
                    let subtitleStreamID = PlayerViewModel.preferredSubtitleStreamID(
                        inPart: part,
                        preferredLanguage: preferences.defaultSubtitleLanguage,
                        forcedOnly: preferences.subtitleForcedOnly
                    )
                    let result = try await plexService.airPlayStreamURL(
                        ratingKey: ratingKey,
                        mediaIndex: mediaIndex,
                        sessionIdentifier: sessionIdentifier,
                        transcodeSessionID: airPlaySessionID,
                        audioStreamID: audioStreamID,
                        subtitleStreamID: subtitleStreamID
                    )
                    guard case .transcodeAvailable = result.outcome else {
                        stopTranscodeSessionInBackground(airPlaySessionID)
                        loadError = airPlayUnavailableMessage(for: result.outcome)
                        return false
                    }

                    playbackURL = result.url
                    sanitizedURL = plexService.sanitizedPlaybackURLString(for: result.url)
                    playbackDecision = .airPlay
                    transcodeSessionID = airPlaySessionID
                    engineType = .avPlayer
                    resolverReason = "AirPlay route selected; Plex receiver-compatible HLS"
                    activeAudioStreamID = audioStreamID
                    activeSubtitleStreamID = subtitleStreamID
                } else if resolverDecision.requiresServerTranscode {
                    // Delivery ladder: neither local engine can render this
                    // media correctly, so skip direct play and start on the
                    // server-stream rung. On any failure or ambiguity fall
                    // back to direct play so playback still starts.
                    let mediaIndex = details.media.firstIndex { $0.id == media.id } ?? 0
                    let serverStreamSessionID = UUID().uuidString
                    do {
                        let result = try await plexService.serverStreamURL(
                            ratingKey: ratingKey,
                            mediaIndex: mediaIndex,
                            sessionIdentifier: sessionIdentifier,
                            transcodeSessionID: serverStreamSessionID
                        )
                        if case .transcodeAvailable = result.outcome {
                            playbackURL = result.url
                            sanitizedURL = plexService.sanitizedPlaybackURLString(for: result.url)
                            playbackDecision = .serverStream
                            transcodeSessionID = serverStreamSessionID
                            engineType = preferences.forceVLCKit ? .vlcKit : .avPlayer
                            resolverReason = "Server stream: \(resolverDecision.reason)"
                        } else {
                            playbackSessionLogger.notice(
                                "Server stream unavailable for ratingKey \(ratingKey, privacy: .public) (outcome \(String(describing: result.outcome), privacy: .public)); proceeding with direct play"
                            )
                        }
                    } catch {
                        playbackSessionLogger.error(
                            "Server stream request failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public); proceeding with direct play"
                        )
                    }
                }
            }

            // The attempt may have been superseded while resolving the stream
            // (metadata fetch or server-stream decision). Abort and release any
            // transcode session we started so it doesn't linger on the server.
            guard currentPlaybackAttemptID == attemptID else {
                if let transcodeSessionID {
                    stopTranscodeSessionInBackground(transcodeSessionID)
                }
                return false
            }

            let serverID = downloadManager?.serverID(for: ratingKey) ?? plexService.currentServerIdentifier
            // Hub/list responses can carry the current Plex viewOffset even when
            // the item-detail response omits it. Keep that initiating offset as
            // a fallback so tapping a visible "Resume" item cannot silently
            // become playback from zero. A detail offset still wins when Plex
            // returns one, and the explicit startPositionOverride used by
            // "Play From Start" wins below.
            let detailViewOffset = details.viewOffset.flatMap { $0 > 0 ? $0 : nil }
            let initiatingViewOffset = resumeOffsetMilliseconds.flatMap { $0 > 0 ? $0 : nil }
            let serverViewOffset = detailViewOffset ?? initiatingViewOffset
            let effectiveViewOffset = usesLocalDownload
                ? offlinePlaybackSyncManager?.effectiveViewOffsetMs(
                    serverID: serverID,
                    ratingKey: ratingKey,
                    fallback: serverViewOffset
                  )
                : serverViewOffset
            let startPosition = startPositionOverride ?? effectiveViewOffset.map { TimeInterval($0) / 1000.0 }
            let attemptContext = PlaybackAttemptContext(
                attemptID: attemptID,
                title: details.title,
                ratingKey: ratingKey,
                engine: engineType,
                resolverReason: resolverReason,
                mediaID: media.id,
                partID: part.id,
                sanitizedPlaybackURL: sanitizedURL
            )

            playbackSessionLogger.notice(
                "Playback attempt \(attemptContext.attemptLabel, privacy: .public) prepared for ratingKey \(ratingKey, privacy: .public), title \(details.title, privacy: .public), engine \(String(describing: engineType), privacy: .public), media \(media.id, privacy: .public), part \(part.id, privacy: .public), startPosition=\(String(describing: startPosition), privacy: .public), reason \(resolverReason, privacy: .public), URL \(sanitizedURL, privacy: .public)"
            )

            let newEngine = PlaybackEngineFactory.makeEngine(type: engineType)
            // Server streams are HLS from the Plex transcoder; like manual
            // transcodes they keep the native renderer as the video path.
            let videoEnhancementRequest: VideoEnhancementRequest
            if case .serverStream = playbackDecision {
                videoEnhancementRequest = .disabled
            } else if case .airPlay = playbackDecision {
                videoEnhancementRequest = .disabled
            } else {
                videoEnhancementRequest = VideoEnhancementRequest.make(
                    mode: preferences.videoEnhancementMode,
                    media: media,
                    part: part
                )
            }
            newEngine.configureVideoEnhancement(videoEnhancementRequest)
            newEngine.onPlaybackEnded = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handlePlaybackEnded()
                }
            }
            newEngine.setPictureInPictureDelegate(self)

            isPictureInPictureActive = false
            pendingPictureInPictureRestoreCompletion = nil
            hasScrobbled = false
            // The next attempt is now live: tear down the Up Next overlay (kept
            // visible during the load so it doubled as the loading state) and
            // the credits poster.
            upNextPresentation = nil
            upNextPoster = nil
            // A new item gets its own one-shot auto-skips.
            spentAutoSkipMarkerIDs = []
            didFinalizeCurrentSession = false
            lastReportedTimeMs = 0
            lastReportedDurationMs = 0
            self.ratingKey = ratingKey
            if !wantsAirPlay {
                activeAudioStreamID = PlayerViewModel.preferredAudioStreamID(
                    inPart: part,
                    preferredLanguage: preferences.defaultAudioLanguage
                )
                activeSubtitleStreamID = PlayerViewModel.preferredSubtitleStreamID(
                    inPart: part,
                    preferredLanguage: preferences.defaultSubtitleLanguage,
                    forcedOnly: preferences.subtitleForcedOnly
                )
            }
            activePlaybackServerID = serverID
            activePlaybackUsesLocalDownload = usesLocalDownload
            activePlaybackSessionIdentifier = sessionIdentifier
            activeTranscodeSessionID = transcodeSessionID
            activeItemDetails = details
            engine = newEngine
            let preferredAudioTrackPosition: Int? = switch playbackDecision {
            case .directPlay, .localDownload:
                // Chosen pre-start so VLCKit opens on the winning track and
                // never has to switch (and restart the audio output) mid-start.
                PlayerViewModel.preferredAudioStreamPosition(
                    inPart: part,
                    preferredLanguage: preferences.defaultAudioLanguage
                )
            case .transcode, .serverStream, .airPlay, .liveTV:
                // HLS rewrites the stream layout; positions no longer apply.
                nil
            }
            let audioStreamSummary = part.streams
                .filter { $0.streamType == .audio }
                .map { stream in
                    "[\(stream.displayTitle ?? stream.codec ?? "?") lang=\(stream.languageCode ?? stream.languageTag ?? "nil") ch=\(stream.channels.map(String.init) ?? "?") default=\(stream.isDefault ?? false) selected=\(stream.isSelected ?? false)]"
                }
                .joined(separator: " ")
            let preferredLanguageLabel = preferences.defaultAudioLanguage
            playbackSessionLogger.notice(
                "Audio preselect position=\(preferredAudioTrackPosition.map(String.init) ?? "none", privacy: .public) preferredLanguage=\(preferredLanguageLabel, privacy: .public) streams=\(audioStreamSummary, privacy: .public)"
            )
            playbackSource = PlaybackSource(
                url: playbackURL,
                startPosition: startPosition,
                context: attemptContext,
                preferredAudioTrackPosition: preferredAudioTrackPosition,
                locality: sourceLocality(for: playbackURL)
            )
            debugInfo = PlaybackDebugInfo(
                title: details.title,
                engine: engineType,
                decision: playbackDecision,
                media: media,
                part: part,
                attemptID: attemptID,
                resolverReason: resolverReason,
                sanitizedPlaybackURL: sanitizedURL
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

            if case .directPlay = playbackDecision {
                // Online direct play gets the automatic delivery-ladder watch:
                // if the engine dies, the session swaps to a server stream.
                startDirectPlayFallbackWatch()
            }

            return true
        } catch {
            // Don't surface an error for a superseded/dismissed attempt.
            guard currentPlaybackAttemptID == attemptID else { return false }
            playbackSessionLogger.error(
                "Playback attempt failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            loadError = error.localizedDescription
            return false
        }
    }

    func switchQuality(to preset: PlaybackQualityPreset, audioStreamID: Int? = nil) async {
        guard !isSwitchingQuality else { return }
        guard !isAirPlayPlaybackActive else {
            presentQualitySwitchError("Quality changes are unavailable while AirPlay is active.")
            return
        }
        guard let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              debugInfo.canSelectPlaybackQuality else {
            presentQualitySwitchError("Quality changes are unavailable for this playback.")
            return
        }
        guard preset != debugInfo.qualityPreset || audioStreamID != nil else { return }
        guard debugInfo.availableQualityPresets.contains(preset) else {
            presentQualitySwitchError("Choose a quality below the original stream.")
            return
        }

        isSwitchingQuality = true
        qualitySwitchError = nil
        defer { isSwitchingQuality = false }

        guard let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              mediaIndex < details.media.count,
              let part = details.media[mediaIndex].parts.first else {
            presentQualitySwitchError("Could not resolve the current media version.")
            return
        }

        let media = details.media[mediaIndex]
        let currentTime = engine?.currentTime ?? playbackSource?.startPosition ?? 0
        let attemptID = UUID()

        do {
            let playbackURL: URL
            let sanitizedURL: String
            let playbackDecision: PlaybackDecision
            let engineType: PlaybackEngineType
            let resolverReason: String
            let videoEnhancementRequest: VideoEnhancementRequest

            if preset.isOriginal {
                guard let directPlayURL = plexService.directPlayURL(for: part) else {
                    presentQualitySwitchError("Could not construct direct-play URL.")
                    return
                }

                let resolverDecision = StreamResolver.evaluate(
                    media: media,
                    forceAVPlayer: preferences.forceAVPlayer,
                    forceVLCKit: preferences.forceVLCKit
                )
                playbackURL = directPlayURL
                sanitizedURL = plexService.sanitizedPlaybackURLString(for: directPlayURL)
                playbackDecision = .directPlay
                engineType = resolverDecision.engine
                resolverReason = resolverDecision.reason
                videoEnhancementRequest = VideoEnhancementRequest.make(
                    mode: preferences.videoEnhancementMode,
                    media: media,
                    part: part
                )
                // Plex session hygiene: returning to Original releases the
                // server transcoder that fed the previous quality.
                if let oldTranscodeSessionID = activeTranscodeSessionID {
                    stopTranscodeSessionInBackground(oldTranscodeSessionID)
                }
                activeTranscodeSessionID = nil
            } else {
                let playbackSessionID = activePlaybackSessionIdentifier ?? UUID().uuidString
                activePlaybackSessionIdentifier = playbackSessionID
                let newTranscodeSessionID = UUID().uuidString

                let result = try await plexService.transcodeURL(
                    ratingKey: ratingKey,
                    mediaIndex: mediaIndex,
                    preset: preset,
                    sessionIdentifier: playbackSessionID,
                    transcodeSessionID: newTranscodeSessionID,
                    audioStreamID: audioStreamID
                )

                switch result.outcome {
                case .transcodeAvailable:
                    // Plex session hygiene: stop the previous transcoder only
                    // after the new session is confirmed, so a failed switch
                    // keeps the current stream running (doc invariant).
                    if let oldTranscodeSessionID = activeTranscodeSessionID {
                        stopTranscodeSessionInBackground(oldTranscodeSessionID)
                    }
                    activeTranscodeSessionID = newTranscodeSessionID
                    playbackURL = result.url
                case .directPlayOnly:
                    presentQualitySwitchError("Plex reported that this item can only direct play.")
                    return
                case let .failed(message):
                    presentQualitySwitchError(message ?? "Plex could not start a transcode session.")
                    return
                }

                sanitizedURL = plexService.sanitizedPlaybackURLString(for: playbackURL)
                playbackDecision = .transcode(preset)
                engineType = preferences.forceVLCKit ? .vlcKit : .avPlayer
                resolverReason = audioStreamID != nil
                    ? "Server transcode for locally undecodable audio stream (quality \(preset.displayName))"
                    : "User selected Plex HLS transcode quality \(preset.displayName)"
                videoEnhancementRequest = .disabled
            }

            activateReplacementAttempt(
                transitionLabel: "switching quality",
                attemptID: attemptID,
                details: details,
                ratingKey: ratingKey,
                media: media,
                part: part,
                playbackURL: playbackURL,
                sanitizedURL: sanitizedURL,
                playbackDecision: playbackDecision,
                engineType: engineType,
                resolverReason: resolverReason,
                videoEnhancementRequest: videoEnhancementRequest,
                startPosition: currentTime
            )
        } catch {
            playbackSessionLogger.error(
                "Quality switch failed for ratingKey \(ratingKey, privacy: .public), preset \(preset.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            presentQualitySwitchError(error.localizedDescription)
        }
    }

    /// Restarts the current session as a server transcode pinned to the given
    /// audio stream (nil = the part's default audio stream). Used when the
    /// local engine cannot decode a track (e.g. TrueHD on the bundled VLCKit
    /// build): the server decodes it to an AVPlayer-friendly stream, so the
    /// user's choice produces sound instead of a dead local decoder.
    func transcodeForUndecodableAudio(_ track: AudioTrack?) async {
        guard let debugInfo else {
            presentQualitySwitchError("Audio transcoding is unavailable for this playback.")
            return
        }
        guard let preset = debugInfo.availableQualityPresets.first(where: { !$0.isOriginal }) else {
            presentQualitySwitchError("No transcode quality is available for this item.")
            return
        }

        let audioStreams = debugInfo.part.streams.filter { $0.streamType == .audio }
        let fallbackStream = audioStreams.first { $0.isSelected ?? false }
            ?? audioStreams.first { $0.isDefault ?? false }
            ?? audioStreams.first
        let streamID = track?.plexStreamID ?? fallbackStream?.id

        playbackSessionLogger.notice(
            "Switching to server transcode for locally undecodable audio (streamID \(streamID.map(String.init) ?? "default", privacy: .public), preset \(preset.displayName, privacy: .public))"
        )
        await switchQuality(to: preset, audioStreamID: streamID)
    }

    // MARK: - AirPlay delivery

    /// Called by the route observer when the system picker connects or removes
    /// an AirPlay destination. Disconnecting intentionally keeps the prepared
    /// HLS source for the rest of the item; reconnecting a direct/local source
    /// replaces it with receiver-compatible HLS at the same position.
    func airPlayRouteSelectionDidChange(_ isSelected: Bool) {
        noteActivePlaybackState(latestActivePlaybackState)
        guard isSelected else { return }
        guard engine != nil, playbackSource != nil, !didFinalizeCurrentSession else { return }

        switch debugInfo?.decision {
        case .airPlay, .transcode, .serverStream, .liveTV:
            // These are already AVPlayer-compatible HLS unless a debug-only
            // force-VLCKit preference is active. Ordinary sessions can hand off
            // immediately without rebuilding the Plex source.
            if engine?.supportsExternalPlayback == true { return }
        case .directPlay, .localDownload:
            break
        case nil:
            return
        }

        scheduleAirPlayTransition()
    }

    /// Records original Plex stream selections made in the player. While an
    /// AirPlay HLS session is active, a change requires a new server stream so
    /// unsupported subtitle formats can remain burned and audio is deterministic
    /// across third-party receivers.
    func selectPlexStreamsForPlayback(audioStreamID: Int?, subtitleStreamID: Int?) {
        let didChange = activeAudioStreamID != audioStreamID ||
            activeSubtitleStreamID != subtitleStreamID
        activeAudioStreamID = audioStreamID
        activeSubtitleStreamID = subtitleStreamID

        guard didChange, isAirPlaySession else { return }
        scheduleAirPlayTransition(isTrackChange: true)
    }

    /// Serializes route and track transitions. A rapid second selection cancels
    /// the in-flight request, waits for its cleanup, then prepares only the most
    /// recent stream selection.
    func scheduleAirPlayTransition(isTrackChange: Bool = false) {
        let previousTask = airPlayTransitionTask
        previousTask?.cancel()
        airPlayTransitionTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            await self?.prepareCurrentSessionForAirPlay(isTrackChange: isTrackChange)
        }
    }

    func prepareCurrentSessionForAirPlay(isTrackChange: Bool = false) async {
        guard !isPreparingAirPlay, !isSwitchingQuality,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              activeLiveTVContext == nil else {
            if activeLiveTVContext != nil, engine?.supportsExternalPlayback != true {
                engine?.pause()
                presentQualitySwitchError("AirPlay requires AVPlayer for Live TV. Disable Force VLCKit and retune the channel.")
            }
            return
        }

        guard plexService.isConnected else {
            engine?.pause()
            presentQualitySwitchError("Connect to the matching Plex server to AirPlay this item.")
            return
        }

        guard let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first else {
            presentQualitySwitchError("Could not resolve the current media version for AirPlay.")
            return
        }

        isPreparingAirPlay = true
        defer { isPreparingAirPlay = false }

        let oldEngine = engine
        let wasPlaying = oldEngine?.state != .paused
        let resumePosition = max(
            oldEngine?.currentTime ?? 0,
            TimeInterval(lastReportedTimeMs) / 1000.0,
            playbackSource?.startPosition ?? 0
        )
        let playbackSessionID = activePlaybackSessionIdentifier ?? UUID().uuidString
        activePlaybackSessionIdentifier = playbackSessionID
        let newTranscodeSessionID = UUID().uuidString
        let expectedPresentationID = playerPresentationID

        do {
            let result = try await plexService.airPlayStreamURL(
                ratingKey: ratingKey,
                mediaIndex: mediaIndex,
                sessionIdentifier: playbackSessionID,
                transcodeSessionID: newTranscodeSessionID,
                audioStreamID: activeAudioStreamID,
                subtitleStreamID: activeSubtitleStreamID
            )

            guard !Task.isCancelled,
                  !didFinalizeCurrentSession,
                  playerPresentationID == expectedPresentationID,
                  self.ratingKey == ratingKey else {
                stopTranscodeSessionInBackground(newTranscodeSessionID)
                return
            }
            guard case .transcodeAvailable = result.outcome else {
                stopTranscodeSessionInBackground(newTranscodeSessionID)
                presentQualitySwitchError(airPlayUnavailableMessage(for: result.outcome))
                return
            }

            if let oldTranscodeSessionID = activeTranscodeSessionID {
                stopTranscodeSessionInBackground(oldTranscodeSessionID)
            }
            activeTranscodeSessionID = newTranscodeSessionID
            activateReplacementAttempt(
                transitionLabel: isTrackChange
                    ? "changing AirPlay tracks"
                    : "moving playback to AirPlay",
                attemptID: UUID(),
                details: details,
                ratingKey: ratingKey,
                media: debugInfo.media,
                part: part,
                playbackURL: result.url,
                sanitizedURL: plexService.sanitizedPlaybackURLString(for: result.url),
                playbackDecision: .airPlay,
                engineType: .avPlayer,
                resolverReason: isTrackChange
                    ? "AirPlay HLS rebuilt for selected Plex tracks"
                    : "AirPlay route selected; Plex receiver-compatible HLS",
                videoEnhancementRequest: .disabled,
                startPosition: resumePosition,
                shouldAutoPlay: wasPlaying
            )
        } catch {
            stopTranscodeSessionInBackground(newTranscodeSessionID)
            guard !Task.isCancelled else { return }
            playbackSessionLogger.error(
                "AirPlay preparation failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            presentQualitySwitchError("Couldn’t prepare AirPlay: \(error.localizedDescription)")
        }
    }

    func airPlayUnavailableMessage(for outcome: PlexService.TranscodeDecisionOutcome) -> String {
        switch outcome {
        case .transcodeAvailable:
            "AirPlay is available."
        case .directPlayOnly:
            "Plex could not prepare a TV-compatible AirPlay stream for this item."
        case let .failed(message):
            message ?? "Plex could not prepare this item for AirPlay."
        }
    }

    /// Swaps the live session onto a new engine/source without finalizing it:
    /// shared mechanics for quality switches and the automatic direct-play →
    /// server-stream fallback. Keeps timeline reporting, scrobble state, and
    /// the Plex session identifier intact; the new `playerPresentationID`
    /// rebuilds the player view, which loads the new source.
    private func activateReplacementAttempt(
        transitionLabel: String,
        attemptID: UUID,
        details: PlexMediaDetails,
        ratingKey: String,
        media: PlexMedia,
        part: PlexMediaPart,
        playbackURL: URL,
        sanitizedURL: String,
        playbackDecision: PlaybackDecision,
        engineType: PlaybackEngineType,
        resolverReason: String,
        videoEnhancementRequest: VideoEnhancementRequest,
        startPosition: TimeInterval?,
        shouldAutoPlay: Bool = true
    ) {
        let attemptContext = PlaybackAttemptContext(
            attemptID: attemptID,
            title: details.title,
            ratingKey: ratingKey,
            engine: engineType,
            resolverReason: resolverReason,
            mediaID: media.id,
            partID: part.id,
            sanitizedPlaybackURL: sanitizedURL
        )

        playbackSessionLogger.notice(
            "Playback attempt \(attemptContext.attemptLabel, privacy: .public) \(transitionLabel, privacy: .public) for ratingKey \(ratingKey, privacy: .public), title \(details.title, privacy: .public), engine \(String(describing: engineType), privacy: .public), media \(media.id, privacy: .public), part \(part.id, privacy: .public), startPosition=\(String(describing: startPosition), privacy: .public), reason \(resolverReason, privacy: .public), URL \(sanitizedURL, privacy: .public)"
        )

        let newEngine = PlaybackEngineFactory.makeEngine(type: engineType)
        newEngine.configureVideoEnhancement(videoEnhancementRequest)
        newEngine.onPlaybackEnded = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handlePlaybackEnded()
            }
        }

        cancelDirectPlayFallbackWatch()
        engine?.onPlaybackEnded = nil
        engine?.setPictureInPictureDelegate(nil)
        engine?.stop()
        newEngine.setPictureInPictureDelegate(self)
        isPictureInPictureActive = false
        pendingPictureInPictureRestoreCompletion = nil
        engine = newEngine
        let preferredAudioTrackPosition: Int? = switch playbackDecision {
        case .directPlay, .localDownload:
            PlayerViewModel.preferredAudioStreamPosition(
                inPart: part,
                preferredLanguage: preferences.defaultAudioLanguage
            )
        case .transcode, .serverStream, .airPlay, .liveTV:
            // HLS rewrites the stream layout; positions no longer apply.
            nil
        }
        playbackSource = PlaybackSource(
            url: playbackURL,
            startPosition: startPosition,
            shouldAutoPlay: shouldAutoPlay,
            context: attemptContext,
            preferredAudioTrackPosition: preferredAudioTrackPosition,
            locality: sourceLocality(for: playbackURL)
        )
        debugInfo = PlaybackDebugInfo(
            title: details.title,
            engine: engineType,
            decision: playbackDecision,
            media: media,
            part: part,
            attemptID: attemptID,
            resolverReason: resolverReason,
            sanitizedPlaybackURL: sanitizedURL
        )
        activePlaybackUsesLocalDownload = false
        playerPresentationID = UUID()
        nowPlayingController.beginSession(
            details: details,
            engine: newEngine,
            plexService: plexService,
            skipBackwardInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
            skipForwardInterval: preferences.playerDoubleTapForwardInterval.timeInterval
        )

        if case .directPlay = playbackDecision {
            // Returning to Original direct play re-arms the ladder watch.
            startDirectPlayFallbackWatch()
        }
    }

    /// Downloads play from disk; everything else inherits the locality of the
    /// session's server connection (LAN vs remote/relay). VLCKit sizes its
    /// protective caching — and with it the silent stretch before audio joins
    /// at start and after seeks — from this.
    func sourceLocality(for url: URL) -> PlaybackSourceLocality {
        if url.isFileURL { return .localFile }
        return plexService.isConnectedViaLocalNetwork ? .localNetwork : .remoteNetwork
    }

    // MARK: - Automatic delivery-ladder fallback

    /// Arms the one-shot direct-play failure watch for the current attempt.
    /// While an online direct-play session is live, a ~500 ms cadence loop
    /// observes the engine; when it reports a terminal error the session is
    /// swapped to the server-stream ladder rung instead of dying on the error
    /// overlay. Cancelled by finalize/clear and by every engine swap; never
    /// armed for local downloads or server streams/transcodes.
    func startDirectPlayFallbackWatch() {
        cancelDirectPlayFallbackWatch()
        isAutomaticDirectPlayFallbackAvailable = true

        let expectedPresentationID = playerPresentationID
        directPlayFallbackWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                guard let self else { return }
                guard self.playerPresentationID == expectedPresentationID,
                      !self.didFinalizeCurrentSession,
                      let engine = self.engine else {
                    return
                }
                guard engine.state == .error || engine.error != nil else { continue }

                // One-shot: consume the watch before attempting the swap so a
                // failed fallback leaves the normal error surface alone.
                self.directPlayFallbackWatchTask = nil
                self.isAutomaticDirectPlayFallbackActive = true
                await self.performDirectPlayServerStreamFallback()
                return
            }
        }
    }

    func cancelDirectPlayFallbackWatch() {
        directPlayFallbackWatchTask?.cancel()
        directPlayFallbackWatchTask = nil
        isAutomaticDirectPlayFallbackAvailable = false
        isAutomaticDirectPlayFallbackActive = false
    }

    /// One-shot delivery-ladder fallback: an online direct-play attempt died
    /// with an engine error, so restart at the same position as a server HLS
    /// stream (direct-stream/remux). If this attempt itself fails, the normal
    /// error surface stays in place — there is no rung below this one.
    func performDirectPlayServerStreamFallback() async {
        defer {
            isAutomaticDirectPlayFallbackAvailable = false
            isAutomaticDirectPlayFallbackActive = false
        }

        guard !didFinalizeCurrentSession,
              !activePlaybackUsesLocalDownload,
              !isSwitchingQuality,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              case .directPlay = debugInfo.decision,
              let engine else {
            return
        }

        let failureDescription = engine.error?.errorDescription ?? "engine reported state .error"
        // The engine's clock may die before its initial resume seek lands and
        // before the first timeline tick. Preserve the source's saved Plex
        // offset as well as any position the engine or timeline reached.
        let resumePosition = max(
            engine.currentTime,
            TimeInterval(lastReportedTimeMs) / 1000.0,
            playbackSource?.startPosition ?? 0
        )

        playbackSessionLogger.error(
            "Playback attempt \(debugInfo.attemptLabel, privacy: .public) direct play failed for ratingKey \(ratingKey, privacy: .public): \(failureDescription, privacy: .public); attempting server-stream fallback from \(resumePosition, privacy: .public)s"
        )

        guard let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first else {
            playbackSessionLogger.error(
                "Server-stream fallback aborted for ratingKey \(ratingKey, privacy: .public): could not resolve the active media version"
            )
            return
        }
        let media = details.media[mediaIndex]

        let playbackSessionID = activePlaybackSessionIdentifier ?? UUID().uuidString
        activePlaybackSessionIdentifier = playbackSessionID
        let transcodeSessionID = UUID().uuidString
        let expectedPresentationID = playerPresentationID

        do {
            let result = try await plexService.serverStreamURL(
                ratingKey: ratingKey,
                mediaIndex: mediaIndex,
                sessionIdentifier: playbackSessionID,
                transcodeSessionID: transcodeSessionID
            )

            // The session may have been torn down or replaced while awaiting
            // the server's decision.
            guard !didFinalizeCurrentSession,
                  playerPresentationID == expectedPresentationID,
                  self.ratingKey == ratingKey else {
                stopTranscodeSessionInBackground(transcodeSessionID)
                return
            }

            guard case .transcodeAvailable = result.outcome else {
                playbackSessionLogger.error(
                    "Server-stream fallback unavailable for ratingKey \(ratingKey, privacy: .public) (outcome \(String(describing: result.outcome), privacy: .public)); leaving the error surface in place"
                )
                return
            }

            activeTranscodeSessionID = transcodeSessionID
            activateReplacementAttempt(
                transitionLabel: "falling back to server stream after direct-play failure",
                attemptID: UUID(),
                details: details,
                ratingKey: ratingKey,
                media: media,
                part: part,
                playbackURL: result.url,
                sanitizedURL: plexService.sanitizedPlaybackURLString(for: result.url),
                playbackDecision: .serverStream,
                engineType: preferences.forceVLCKit ? .vlcKit : .avPlayer,
                resolverReason: "Direct play failed (\(failureDescription)); automatic server-stream fallback",
                videoEnhancementRequest: .disabled,
                startPosition: resumePosition
            )
        } catch {
            playbackSessionLogger.error(
                "Server-stream fallback failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public); leaving the error surface in place"
            )
        }
    }

    /// Fire-and-forget `/video/:/transcode/universal/stop` for Plex session
    /// hygiene; `PlexService` logs failures instead of throwing.
    func stopTranscodeSessionInBackground(_ transcodeSessionID: String) {
        Task {
            await plexService.stopTranscodeSession(transcodeSessionID: transcodeSessionID)
        }
    }

    func handlePlaybackEnded() async {
        guard !isHandlingPlaybackEnded else { return }
        guard upNextPresentation == nil else { return }
        isHandlingPlaybackEnded = true
        defer { isHandlingPlaybackEnded = false }

        // The credits poster is up: its mode already decided how the episode
        // should end when it was raised.
        if let poster = upNextPoster {
            if poster.autoAdvancesAtEnd {
                // Continue straight into the next episode with no full-screen
                // Up Next screen — the poster already gave the heads-up.
                await startUpNextPosterPlayback(trigger: .autoplay)
            } else {
                // Manual mode (continuous play off / passout protection): fall
                // back to the full-screen "Are You Still Watching?" screen.
                let episode = poster.episode
                dismissUpNextPoster()
                finalizeCurrentPlaybackSession(markCompleted: true)
                presentUpNext(for: episode)
            }
            return
        }

        if let activeItemDetails,
           activeItemDetails.type == .episode,
           let nextEpisode = await nextEpisode(after: activeItemDetails) {
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
        airPlayTransitionTask?.cancel()
        airPlayTransitionTask = nil
        isPreparingAirPlay = false
        cancelDirectPlayFallbackWatch()

        // Plex session hygiene: release the server transcoder with the session.
        if let transcodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(transcodeSessionID)
            activeTranscodeSessionID = nil
        }

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

            if activeLiveTVContext == nil,
               !hasScrobbled,
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

        if markCompleted, durationMs > 0, activeLiveTVContext == nil {
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
        cancelUpNextPosterCountdown()
        cancelDirectPlayFallbackWatch()
        airPlayTransitionTask?.cancel()
        airPlayTransitionTask = nil
        isPreparingAirPlay = false
        upNextPresentation = nil
        upNextPoster = nil
        spentAutoSkipMarkerIDs = []
        engine?.onPlaybackEnded = nil
        engine?.setPictureInPictureDelegate(nil)
        nowPlayingController.endSession()
        engine = nil
        // Normally already stopped by finalize; belt-and-braces for paths
        // that clear without finalizing.
        if let transcodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(transcodeSessionID)
        }
        isPictureInPictureActive = false
        pendingPictureInPictureRestoreCompletion = nil
        activeItemDetails = nil
        cancelLiveTVScheduleRefresh()
        activeLiveTVContext = nil
        activePlaybackServerID = nil
        activePlaybackUsesLocalDownload = false
        activeAudioStreamID = nil
        activeSubtitleStreamID = nil
        debugInfo = nil
        playbackSource = nil
        ratingKey = nil
        qualitySwitchError = nil
        loadError = nil
        loadingPlaceholder = nil
        currentPlaybackAttemptID = nil
        activePlaybackSessionIdentifier = nil
        activeTranscodeSessionID = nil
        hasScrobbled = false
        didFinalizeCurrentSession = false
        isHandlingPlaybackEnded = false
        lastReportedTimeMs = 0
        lastReportedDurationMs = 0
        continuousPlayEpisodeRunCount = 0
        latestActivePlaybackState = .idle
        isIdleTimerSuppressed = false
    }

    private func presentQualitySwitchError(_ message: String) {
        qualitySwitchError = message
        let expectedMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard self?.qualitySwitchError == expectedMessage else { return }
            self?.qualitySwitchError = nil
        }
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
