import AVFoundation
import Foundation
import OSLog

private let playbackSessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlaybackSession"
)

/// How one attempt on one server ended.
enum PlaybackSessionOutcome {
    case started
    /// This server can't deliver the item, but another one might: the details
    /// fetch failed, the server is gone, there is no playable part, the
    /// transcode decision failed, or no URL could be built.
    case hardFailure(String)
    /// A newer attempt or a dismissal took over while this one loaded.
    case superseded
}

extension PlaybackCoordinator {
    /// How long one candidate server gets to answer before the walk moves on.
    /// The session's own 15 s request timeout is the right ceiling for the last
    /// candidate, but waiting it out on each of them would turn a fallback into
    /// half a minute of spinner. Generous enough for a sleeping NAS to spin its
    /// disks up and answer a `checkFiles` metadata request.
    static let candidateFetchDeadline: Duration = .seconds(10)

    /// Plays `id`, walking the item's other servers when one of them fails
    /// hard. Sets `loadError` when nothing could be started.
    ///
    /// `resumeOffsetMilliseconds` is the offset of the instance the user
    /// actually picked, so that instance plays first even when a
    /// higher-priority server also has the item: the progress belongs to this
    /// copy, and splitting it across two servers is what makes a series resume
    /// in two places. A fallback server only inherits the offset when its own
    /// copy is the same length (`resumeOffsetDurationMilliseconds`, within 2 %)
    /// — otherwise it starts from whatever position that server itself knows.
    @discardableResult
    func runPlaybackAttempt(
        id: PlexItemID,
        startPositionOverride: TimeInterval?,
        resumeOffsetMilliseconds: Int?,
        resumeOffsetDurationMilliseconds: Int? = nil,
        selectedMediaID: Int?,
        restrictToItemServer: Bool = false,
        attemptID: UUID
    ) async -> Bool {
        let isPlayableOffline = downloadManager?.isPlayableOffline(id: id) == true
        let resolution = await PlaybackSourceResolver(plexService: plexService).resolve(
            for: id,
            // An explicitly chosen media version only exists on its own server.
            restrictToItemServer: restrictToItemServer || selectedMediaID != nil,
            prefersRequestedInstance: (resumeOffsetMilliseconds ?? 0) > 0
        )
        guard !Task.isCancelled, currentPlaybackAttemptID == attemptID else { return false }

        // Every usable copy needs an entitlement the account doesn't have, so
        // say so once instead of letting each server fail in turn. A completed
        // download plays regardless — it needs no server at all.
        if resolution.isFullyRestricted,
           let restrictionMessage = resolution.restrictionMessage,
           !isPlayableOffline {
            playbackSessionLogger.notice(
                "Blocking remote playback for \(id.storageKey, privacy: .public): every candidate server is remote-streaming restricted"
            )
            loadError = restrictionMessage
            return false
        }

        var candidates = resolution.identifiers
        if isPlayableOffline {
            // The downloaded file belongs to the server it came from and plays
            // with no connection, so it always goes first.
            candidates = [id] + candidates.filter { $0 != id }
        }
        if candidates.isEmpty {
            // Nothing connected. Try the item as asked anyway: this is the
            // offline path, and it surfaces the normal error when it is not.
            candidates = [id]
        }

        var firstFailureMessage: String?

        for (index, candidate) in candidates.enumerated() {
            let isLastCandidate = index == candidates.index(before: candidates.endIndex)
            let outcome = await startPlaybackSession(
                id: candidate,
                startPositionOverride: startPositionOverride,
                resumeOffsetMilliseconds: resumeOffsetMilliseconds,
                resumeOffsetDurationMilliseconds: resumeOffsetDurationMilliseconds,
                // Only the copy the offset was measured on may use it blindly.
                // Both spellings count: the resolver fills in a missing server.
                carriesRequestedOffset: candidate == id || candidate == resolution.requestedID,
                selectedMediaID: selectedMediaID,
                attemptID: attemptID,
                fetchDeadline: isLastCandidate ? nil : Self.candidateFetchDeadline
            )

            switch outcome {
            case .started:
                return true
            case .superseded:
                return false
            case let .hardFailure(message):
                firstFailureMessage = firstFailureMessage ?? message
                guard !Task.isCancelled, currentPlaybackAttemptID == attemptID else { return false }
                if !isLastCandidate {
                    playbackSessionLogger.notice(
                        "Playback candidate \(candidate.storageKey, privacy: .public) failed (\(message, privacy: .public)); trying the next server"
                    )
                }
            }
        }

        // The walk ends on the restricted candidates (they always sort last), so
        // when there were any, the last thing that stood between the viewer and
        // the item was the missing Plex Pass — a more useful answer than the
        // first server's own error.
        if !isPlayableOffline,
           resolution.hasRestrictedCandidate,
           let restrictionMessage = resolution.restrictionMessage {
            loadError = restrictionMessage
            return false
        }

        loadError = firstFailureMessage ?? "Could not play this item."
        return false
    }

    /// One attempt on one server.
    ///
    /// - Parameters:
    ///   - carriesRequestedOffset: true when this candidate is the very copy
    ///     `resumeOffsetMilliseconds` was measured on.
    ///   - suppressLocalDownload: ignore the completed download for this item
    ///     and stream from the server instead. Set when the file on disk turned
    ///     out to be unusable.
    ///   - fetchDeadline: bounds the metadata fetch so a dead server does not
    ///     hold the candidate walk for the full request timeout. nil leaves the
    ///     session's own timeout in charge (the last candidate).
    func startPlaybackSession(
        id: PlexItemID,
        startPositionOverride: TimeInterval?,
        resumeOffsetMilliseconds: Int?,
        resumeOffsetDurationMilliseconds: Int? = nil,
        carriesRequestedOffset: Bool = true,
        selectedMediaID: Int?,
        attemptID: UUID,
        suppressLocalDownload: Bool = false,
        fetchDeadline: Duration? = nil
    ) async -> PlaybackSessionOutcome {
        let ratingKey = id.ratingKey
        let itemServerID = id.serverID
        let profileSession = plexService.serverSessionToken
        loadError = nil
        qualitySwitchError = nil
        cancelUpNextCountdown()
        cancelDirectPlayFallbackWatch()
        // A new item gets the Dolby Vision 7 conversion back. Reset here, not
        // at the commit below: the remux request labels its session with it.
        isDolbyVision7ConversionSuppressed = false
        // Any Up Next overlay stays visible as the loading state for the next
        // episode; it's cleared when the new engine commits below.
        // Plex session hygiene: a replaced session that was never finalized
        // (e.g. direct restart) must not leave its server transcoder running.
        if let staleTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(staleTranscodeSessionID, serverID: activePlaybackServerID)
            activeTranscodeSessionID = nil
        }

        do {
            let details: PlexMediaDetails
            if !suppressLocalDownload,
               downloadManager?.isPlayableOffline(id: id) == true,
               let cachedDetails = downloadManager?.cachedMediaDetails(for: id) {
                details = cachedDetails
            } else {
                do {
                    details = try await fetchPlaybackDetails(
                        ratingKey: ratingKey,
                        serverID: itemServerID,
                        deadline: fetchDeadline
                    )
                } catch {
                    if let cachedDetails = downloadManager?.cachedMediaDetails(for: id) {
                        details = cachedDetails
                    } else {
                        throw error
                    }
                }
            }

            // A newer attempt or a dismissal can supersede this one during the
            // metadata fetch; bail before building any playback state.
            guard !Task.isCancelled, currentPlaybackAttemptID == attemptID, profileSession == plexService.serverSessionToken else { return .superseded }

            airPlayController.refreshRoute(notify: false)
            let wantsAirPlay = airPlayController.isAirPlayRouteSelected
            let downloadedURL = downloadManager?.localPlaybackURL(
                for: id,
                selectedMediaID: selectedMediaID
            )
            // AirPlay receivers cannot consume Dusk's private app-container URL.
            // When the matching Plex server is reachable, ask it for HLS even if
            // this item also has a completed local download.
            let localURL = (wantsAirPlay || suppressLocalDownload) ? nil : downloadedURL
            let localMediaVersion = localURL.flatMap { _ in
                downloadManager?.downloadedMediaVersion(
                    for: id,
                    in: details,
                    selectedMediaID: selectedMediaID
                )
            }
            if localURL != nil && localMediaVersion == nil {
                playbackSessionLogger.error(
                    "Playback attempt failed before engine selection for ratingKey \(ratingKey, privacy: .public): local download metadata did not match the downloaded media version"
                )
                // The file on disk is unusable, but the server it came from can
                // still stream the item. Retry this same candidate online rather
                // than ending the walk on a download error.
                return await startPlaybackSession(
                    id: id,
                    startPositionOverride: startPositionOverride,
                    resumeOffsetMilliseconds: resumeOffsetMilliseconds,
                    resumeOffsetDurationMilliseconds: resumeOffsetDurationMilliseconds,
                    carriesRequestedOffset: carriesRequestedOffset,
                    selectedMediaID: selectedMediaID,
                    attemptID: attemptID,
                    suppressLocalDownload: true,
                    fetchDeadline: fetchDeadline
                )
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
                return .hardFailure("No playable media found.")
            }

            // The session's server, in this order: the one the candidate names,
            // the one the downloaded record belongs to, then the primary for an
            // unstamped item. Everything the session reports goes here only.
            let serverID = itemServerID
                ?? downloadManager?.serverID(for: id)
                ?? plexService.pool.primary?.serverID
            let showScope = ShowTrackPreferenceStore.Scope(
                profileID: profileSession.profileID, serverID: serverID, details: details
            )
            let rememberedTracks = showScope.flatMap { showTrackPreferenceStore.preferences(for: $0) }
            let rememberedAudio = rememberedTracks?.audioStream(in: part)
            let hasRememberedMatch = rememberedTracks?.hasMatch(in: part) == true
            let defaultSubtitleID = PlayerViewModel.preferredSubtitleStreamID(
                inPart: part,
                preferredLanguage: preferences.defaultSubtitleLanguage,
                forcedOnly: preferences.subtitleForcedOnly
            )
            let startupSubtitleID = rememberedTracks.map {
                $0.subtitleStreamID(in: part, fallback: defaultSubtitleID)
            } ?? defaultSubtitleID
            let hasHDRVideo = ShowTrackPreferences.hasHDRVideo(in: part)
            // A remembered PGS/ASS choice must not veto the HDR/DV remux and
            // send the video into VLC. Retain the preference for compatible
            // episodes, but start this remux without an unsupported subtitle.
            let remuxSubtitleID = hasRememberedMatch
                ? ShowTrackPreferences.remuxSubtitleStreamID(startupSubtitleID, in: part)
                : startupSubtitleID
            let convertsRememberedAudio = rememberedAudio.map {
                !StreamResolver.canCopyIntoRemux(audio: $0) &&
                    (hasHDRVideo || PlayerViewModel.isLocallyUndecodableAudioCodec($0.codec))
            } == true

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
            var spatialAudioStreamIDs: (audio: Int?, subtitle: Int?, convertsAudio: Bool, restoresDolbyAtmos: Bool)?

            if let localURL {
                playbackURL = localURL
                sanitizedURL = localURL.path
                playbackDecision = .localDownload
                usesLocalDownload = true
            } else {
                // The Plex Pass remote-streaming gate is resolved per candidate
                // by `PlaybackSourceResolver` before we get here, so a
                // restricted server is only reached when it is the last resort.
                if wantsAirPlay, plexService.pool.connection(for: itemServerID) == nil {
                    return .hardFailure("Connect to the matching Plex server to AirPlay this item.")
                }

                guard let directPlayURL = plexService.directPlayURL(for: part, serverID: itemServerID) else {
                    playbackSessionLogger.error(
                        "Playback attempt failed before engine selection for ratingKey \(ratingKey, privacy: .public): could not construct direct play URL for media \(media.id, privacy: .public), part \(part.id, privacy: .public)"
                    )
                    return .hardFailure("Could not construct playback URL.")
                }
                playbackURL = directPlayURL
                sanitizedURL = plexService.sanitizedPlaybackURLString(for: directPlayURL)
                playbackDecision = .directPlay
                usesLocalDownload = false

                if wantsAirPlay {
                    let mediaIndex = details.media.firstIndex { $0.id == media.id } ?? 0
                    let airPlaySessionID = UUID().uuidString
                    let audioStreamID = rememberedAudio?.id ?? PlayerViewModel.preferredAudioStreamID(
                        inPart: part,
                        preferredLanguage: preferences.defaultAudioLanguage
                    )
                    let subtitleStreamID = startupSubtitleID
                    let result = try await plexService.airPlayStreamURL(
                        ratingKey: ratingKey,
                        mediaIndex: mediaIndex,
                        sessionIdentifier: sessionIdentifier,
                        transcodeSessionID: airPlaySessionID,
                        audioStreamID: audioStreamID,
                        subtitleStreamID: subtitleStreamID,
                        serverID: itemServerID
                    )
                    guard case .transcodeAvailable = result.outcome else {
                        stopTranscodeSessionInBackground(airPlaySessionID, serverID: itemServerID)
                        return .hardFailure(airPlayUnavailableMessage(for: result.outcome))
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
                    // Delivery ladder: direct play cannot render this media
                    // correctly (Dolby Vision profile 5). First try a
                    // video-copy remux AVPlayer renders as Dolby Vision, then
                    // the server-stream rung. On any failure or ambiguity fall
                    // back to direct play so playback still starts.
                    let mediaIndex = details.media.firstIndex { $0.id == media.id } ?? 0
                    let audioStreamID = rememberedAudio?.id ?? PlayerViewModel.preferredRemuxAudioStream(
                        inPart: part,
                        preferredLanguage: preferences.defaultAudioLanguage
                    )?.id
                    // A bitmap subtitle would force a video re-encode; start
                    // without it rather than lose Dolby Vision.
                    let subtitleStreamID = remuxSubtitleID.flatMap { id -> Int? in
                        guard let stream = part.streams.first(where: { $0.streamType == .subtitle && $0.id == id }) else {
                            return nil
                        }
                        return StreamResolver.canRideRemux(subtitle: stream) ? id : nil
                    }
                    let dolbyVisionRemux = await requestSpatialAudioRemux(
                        ratingKey: ratingKey,
                        mediaIndex: mediaIndex,
                        media: media,
                        part: part,
                        audioStreamID: audioStreamID,
                        subtitleStreamID: subtitleStreamID,
                        convertsAudio: convertsRememberedAudio,
                        sessionIdentifier: sessionIdentifier,
                        serverID: itemServerID
                    )
                    if let dolbyVisionRemux {
                        playbackURL = dolbyVisionRemux.url
                        sanitizedURL = plexService.sanitizedPlaybackURLString(for: dolbyVisionRemux.url)
                        playbackDecision = .spatialAudio
                        transcodeSessionID = dolbyVisionRemux.transcodeSessionID
                        engineType = .avPlayer
                        resolverReason = dolbyVisionRemux.reason
                        spatialAudioStreamIDs = (
                            audioStreamID, subtitleStreamID,
                            dolbyVisionRemux.convertsAudio, dolbyVisionRemux.restoresDolbyAtmos
                        )
                    } else {
                        let serverStreamSessionID = UUID().uuidString
                        do {
                            let result = try await plexService.serverStreamURL(
                                ratingKey: ratingKey,
                                mediaIndex: mediaIndex,
                                sessionIdentifier: sessionIdentifier,
                                transcodeSessionID: serverStreamSessionID,
                                audioStreamID: hasRememberedMatch ? audioStreamID : nil,
                                subtitleStreamID: hasRememberedMatch ? (subtitleStreamID ?? 0) : nil,
                                serverID: itemServerID
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
                } else {
                    // Dolby Atmos / spatial audio and HDR video: a VLCKit-only
                    // file whose audio is Dolby, or whose video is HDR (HDR10,
                    // HDR10+, HLG, Dolby Vision 7/8), goes to AVPlayer through
                    // a lossless Plex remux. Anything short of a confirmed
                    // copy-remux keeps plain direct play.
                    let remuxAudioStream = rememberedAudio ?? PlayerViewModel.preferredRemuxAudioStream(
                        inPart: part,
                        preferredLanguage: preferences.defaultAudioLanguage
                    )
                    let audioStreamID = remuxAudioStream?.id
                    let subtitleStreamID = remuxSubtitleID
                    let mediaIndex = details.media.firstIndex { $0.id == media.id } ?? 0
                    // The request decides conversion before contacting Plex:
                    // DV7 + TrueHD starts on AVPlayer with E-AC-3 audio.
                    let remux = await requestSpatialAudioRemux(
                        ratingKey: ratingKey,
                        mediaIndex: mediaIndex,
                        media: media,
                        part: part,
                        audioStreamID: audioStreamID,
                        subtitleStreamID: subtitleStreamID,
                        convertsAudio: convertsRememberedAudio,
                        sessionIdentifier: sessionIdentifier,
                        serverID: itemServerID
                    )
                    if let remux {
                        playbackURL = remux.url
                        sanitizedURL = plexService.sanitizedPlaybackURLString(for: remux.url)
                        playbackDecision = .spatialAudio
                        transcodeSessionID = remux.transcodeSessionID
                        engineType = .avPlayer
                        resolverReason = remux.reason
                        spatialAudioStreamIDs = (audioStreamID, subtitleStreamID, remux.convertsAudio, remux.restoresDolbyAtmos)
                    }
                }
            }

            // The attempt may have been superseded while resolving the stream
            // (metadata fetch or server-stream decision). Abort and release any
            // transcode session we started so it doesn't linger on the server.
            guard !Task.isCancelled, currentPlaybackAttemptID == attemptID, profileSession == plexService.serverSessionToken else {
                if let transcodeSessionID {
                    stopTranscodeSessionInBackground(transcodeSessionID, serverID: itemServerID)
                }
                return .superseded
            }

            switch playbackDecision {
            case .directPlay, .localDownload:
                let directDecision = StreamResolver.evaluateForDirectPlayback(
                    media: media,
                    part: part,
                    enhancementMode: preferences.videoEnhancementMode,
                    selectedSubtitleStreamID: startupSubtitleID,
                    forceAVPlayer: preferences.forceAVPlayer,
                    forceVLCKit: preferences.forceVLCKit
                )
                engineType = directDecision.engine
                resolverReason = directDecision.reason
                if hasRememberedMatch,
                   !hasHDRVideo, !preferences.forceAVPlayer,
                   let subtitleID = startupSubtitleID,
                   part.streams.contains(where: { $0.id == subtitleID && $0.key != nil }),
                   !usesLocalDownload {
                    engineType = .vlcKit
                    resolverReason = "Remembered show subtitle; VLCKit mounts Plex sidecar files"
                }
            default:
                break
            }
            // Hub/list responses can carry the current Plex viewOffset even when
            // the item-detail response omits it. Keep that initiating offset as
            // a fallback so tapping a visible "Resume" item cannot silently
            // become playback from zero. A detail offset still wins when Plex
            // returns one, and the explicit startPositionOverride used by
            // "Play From Start" wins below.
            let detailViewOffset = details.viewOffset.flatMap { $0 > 0 ? $0 : nil }
            let initiatingViewOffset = carriedResumeOffsetMs(
                resumeOffsetMilliseconds,
                referenceDurationMs: resumeOffsetDurationMilliseconds,
                candidateDurationMs: details.duration,
                carriesRequestedOffset: carriesRequestedOffset
            )
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
            } else if case .spatialAudio = playbackDecision {
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
            newEngine.applySubtitleFontSize(preferences.subtitleFontSize)
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
            resolvedIntroFingerprintMarkerIDs = []
            introOpeningSessionState = IntroOpeningSessionState()
            didFinalizeCurrentSession = false
            lastReportedTimeMs = 0
            lastReportedDurationMs = 0
            self.ratingKey = ratingKey
            if let spatialAudioStreamIDs {
                // The remux is built around exactly these streams; the player
                // lists and changes them through Plex (server track selection).
                activeAudioStreamID = spatialAudioStreamIDs.audio
                activeSubtitleStreamID = spatialAudioStreamIDs.subtitle
                remuxAudioConversion = spatialAudioStreamIDs.convertsAudio
                    ? RemuxAudioConversion(
                        audioStreamID: spatialAudioStreamIDs.audio,
                        restoresDolbyAtmos: spatialAudioStreamIDs.restoresDolbyAtmos
                    )
                    : nil
            } else if !wantsAirPlay {
                remuxAudioConversion = nil
                activeAudioStreamID = rememberedAudio?.id ?? PlayerViewModel.preferredAudioStreamID(
                    inPart: part, preferredLanguage: preferences.defaultAudioLanguage
                )
                activeSubtitleStreamID = startupSubtitleID
            }
            activePlaybackServerID = serverID
            activeShowTrackScope = showScope
            pendingExplicitTrackSelection = hasRememberedMatch
                ? ExplicitTrackSelection(audioStreamID: activeAudioStreamID, subtitleStreamID: activeSubtitleStreamID)
                : nil
            if let showScope, hasRememberedMatch,
               !usesLocalDownload, !playbackDecision.isSpatialAudio {
                syncShowStreamsToPlex(
                    partID: part.id,
                    audioStreamID: activeAudioStreamID,
                    subtitleStreamID: activeSubtitleStreamID ?? 0,
                    serverID: showScope.serverID
                )
            }
            remuxTrackSelection = playbackDecision.isSpatialAudio
                ? ExplicitTrackSelection(audioStreamID: activeAudioStreamID, subtitleStreamID: activeSubtitleStreamID)
                : nil
            activePlaybackUsesLocalDownload = usesLocalDownload
            activePlaybackSessionIdentifier = sessionIdentifier
            activeTranscodeSessionID = transcodeSessionID
            activeItemDetails = details
            refreshAdjacentEpisodesIfNeeded()
            // Ahead of the engine so the display's mode switch (which blanks the
            // screen briefly) overlaps buffering instead of playback.
            let dolbyVisionRemux = remuxDolbyVisionConfiguration(for: media, decision: playbackDecision)
            let dolbyVision7Conversion = remuxDolbyVision7Conversion(for: media, decision: playbackDecision)
            DisplayModeMatcher.apply(
                media: media,
                part: part,
                decision: playbackDecision,
                dolbyVision: dolbyVision7Conversion ?? dolbyVisionRemux
            )
            engine = newEngine
            let preferredAudioTrackPosition: Int? = switch playbackDecision {
            case .directPlay, .localDownload:
                // Chosen pre-start so VLCKit opens on the winning track and
                // never has to switch (and restart the audio output) mid-start.
                rememberedAudio.flatMap { stream -> Int? in
                    guard !PlayerViewModel.isLocallyUndecodableAudioCodec(stream.codec) else { return nil }
                    return part.streams.filter { $0.streamType == .audio }.firstIndex { $0.id == stream.id }
                } ?? PlayerViewModel.preferredAudioStreamPosition(
                    inPart: part,
                    preferredLanguage: preferences.defaultAudioLanguage
                )
            case .transcode, .serverStream, .spatialAudio, .airPlay, .liveTV:
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
                preferredAudioChannelCount: rememberedAudio?.channels ?? PlayerViewModel.preferredAudioStreamChannelCount(
                    inPart: part,
                    preferredLanguage: preferences.defaultAudioLanguage
                ),
                locality: sourceLocality(for: playbackURL, serverID: serverID),
                restoresDolbyAtmos: playbackDecision.isSpatialAudio && activeAudioStreamIsDolbyAtmos(in: part),
                dolbyVisionRemux: dolbyVisionRemux,
                dolbyVision7Conversion: dolbyVision7Conversion
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
            sharePlayController.playbackItemDidChange(
                activity: currentSharePlayActivity,
                engine: newEngine
            )

            if playbackDecision.isDirectPlay || playbackDecision.isSpatialAudio {
                // Online direct play gets the automatic delivery-ladder watch:
                // if the engine dies, the session swaps to a server stream.
                // A failed Atmos remux falls back to plain direct play.
                startDirectPlayFallbackWatch()
            }

            return .started
        } catch {
            // Don't surface an error for a superseded/dismissed attempt.
            guard !Task.isCancelled, currentPlaybackAttemptID == attemptID, profileSession == plexService.serverSessionToken else { return .superseded }
            playbackSessionLogger.error(
                "Playback attempt failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .hardFailure(error.localizedDescription)
        }
    }

    /// How much of the initiating offset a candidate may use.
    ///
    /// The copy the user picked keeps its own offset unconditionally. Another
    /// server's copy is a different file — a different cut, a different edition,
    /// or a whole other title behind a weak content key — so it only inherits
    /// the position when both copies run for (very nearly) the same length.
    /// Otherwise the fallback server's own `viewOffset` decides where to start.
    private func carriedResumeOffsetMs(
        _ resumeOffsetMilliseconds: Int?,
        referenceDurationMs: Int?,
        candidateDurationMs: Int?,
        carriesRequestedOffset: Bool
    ) -> Int? {
        guard let offset = resumeOffsetMilliseconds, offset > 0 else { return nil }
        guard !carriesRequestedOffset else { return offset }
        guard let referenceDurationMs, referenceDurationMs > 0,
              let candidateDurationMs, candidateDurationMs > 0 else {
            return nil
        }
        let tolerance = Double(referenceDurationMs) * Self.resumeOffsetDurationTolerance
        guard Double(abs(candidateDurationMs - referenceDurationMs)) <= tolerance else {
            return nil
        }
        return offset
    }

    /// How far two copies' runtimes may differ before a carried resume position
    /// stops being meaningful.
    static let resumeOffsetDurationTolerance = 0.02

    /// Fetches the item's details from one server, optionally giving up early
    /// so the candidate walk can move on. The bound is a race rather than a
    /// request timeout because `getMediaDetails` may also answer from the
    /// offline cache, which must not be penalized.
    private func fetchPlaybackDetails(
        ratingKey: String,
        serverID: String?,
        deadline: Duration?
    ) async throws -> PlexMediaDetails {
        guard let deadline else {
            return try await plexService.getMediaDetails(
                ratingKey: ratingKey,
                checkFiles: true,
                serverID: serverID
            )
        }

        // The fetch child is deliberately *not* annotated `@MainActor`:
        // `getMediaDetails` hops there itself, and an explicitly isolated child
        // closure trips the region-based isolation checker (Swift 6).
        return try await withThrowingTaskGroup(of: PlexMediaDetails.self) { group in
            group.addTask { [plexService] in
                try await plexService.getMediaDetails(
                    ratingKey: ratingKey,
                    checkFiles: true,
                    serverID: serverID
                )
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw PlexServiceError.networkError("The server did not answer in time.")
            }

            defer { group.cancelAll() }
            guard let details = try await group.next() else {
                throw PlexServiceError.networkError("The server did not answer in time.")
            }
            return details
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
                guard let directPlayURL = plexService.directPlayURL(
                    for: part,
                    serverID: activePlaybackServerID
                ) else {
                    presentQualitySwitchError("Could not construct direct-play URL.")
                    return
                }

                let resolverDecision = StreamResolver.evaluateForDirectPlayback(
                    media: media,
                    part: part,
                    enhancementMode: preferences.videoEnhancementMode,
                    selectedSubtitleStreamID: activeSubtitleStreamID,
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
                #if os(tvOS)
                // Original restarts a local engine too; retain the choices
                // used above instead of re-running language preferences.
                if resolverDecision.usesEnhancedSubtitleRenderer {
                    pendingExplicitTrackSelection = ExplicitTrackSelection(
                        audioStreamID: activeAudioStreamID,
                        subtitleStreamID: activeSubtitleStreamID
                    )
                }
                #endif
                // Plex session hygiene: returning to Original releases the
                // server transcoder that fed the previous quality.
                if let oldTranscodeSessionID = activeTranscodeSessionID {
                    stopTranscodeSessionInBackground(
                        oldTranscodeSessionID,
                        serverID: activePlaybackServerID
                    )
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
                    audioStreamID: audioStreamID,
                    serverID: activePlaybackServerID
                )

                switch result.outcome {
                case .transcodeAvailable:
                    // Plex session hygiene: stop the previous transcoder only
                    // after the new session is confirmed, so a failed switch
                    // keeps the current stream running (doc invariant).
                    if let oldTranscodeSessionID = activeTranscodeSessionID {
                        stopTranscodeSessionInBackground(
                            oldTranscodeSessionID,
                            serverID: activePlaybackServerID
                        )
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
    /// local engine cannot decode a track (TrueHD on a stock VLCKit build, or
    /// Dusk's TrueHD decoder failing to open): the server decodes it to an
    /// AVPlayer-friendly stream, so the user's choice produces sound instead
    /// of a dead local decoder.
    func transcodeForUndecodableAudio(_ track: AudioTrack?) async {
        guard let debugInfo else {
            presentQualitySwitchError("Audio transcoding is unavailable for this playback.")
            return
        }

        let audioStreams = debugInfo.part.streams.filter { $0.streamType == .audio }
        let fallbackStream = audioStreams.first { $0.isSelected ?? false }
            ?? audioStreams.first { $0.isDefault ?? false }
            ?? audioStreams.first
        let streamID = track?.plexStreamID ?? fallbackStream?.id

        // Preferred: keep the original video (copied, HDR intact) and have
        // Plex convert only the audio. The quality-preset transcode below
        // re-encodes the video and is the last resort — on servers without
        // HDR tone mapping it also fails outright for HDR sources (Plex tags
        // the 8-bit H.264 output PQ, which AVPlayer rejects with -12927).
        if await playConvertedAudioRemux(audioStreamID: streamID) {
            return
        }

        guard let preset = debugInfo.availableQualityPresets.first(where: { !$0.isOriginal }) else {
            presentQualitySwitchError("No transcode quality is available for this item.")
            return
        }

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
        case .directPlay, .localDownload, .spatialAudio:
            // A spatial-audio remux is fMP4/HEVC HLS built for this device,
            // not for an arbitrary receiver: rebuild it as AirPlay HLS.
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

        guard didChange else { return }
        if isSpatialAudioSession {
            scheduleSpatialAudioTrackChange()
            return
        }
        #if os(tvOS)
        switchToVLCKitForEnhancedSubtitlesIfNeeded()
        #endif
        guard isAirPlaySession else { return }
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

        guard plexService.pool.connection(for: activePlaybackServerID) != nil else {
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
                subtitleStreamID: activeSubtitleStreamID,
                serverID: activePlaybackServerID
            )

            guard !Task.isCancelled,
                  !didFinalizeCurrentSession,
                  playerPresentationID == expectedPresentationID,
                  self.ratingKey == ratingKey else {
                stopTranscodeSessionInBackground(newTranscodeSessionID, serverID: activePlaybackServerID)
                return
            }
            guard case .transcodeAvailable = result.outcome else {
                stopTranscodeSessionInBackground(newTranscodeSessionID, serverID: activePlaybackServerID)
                presentQualitySwitchError(airPlayUnavailableMessage(for: result.outcome))
                return
            }

            if let oldTranscodeSessionID = activeTranscodeSessionID {
                stopTranscodeSessionInBackground(
                    oldTranscodeSessionID,
                    serverID: activePlaybackServerID
                )
            }
            activeTranscodeSessionID = newTranscodeSessionID
            activateReplacementAttempt(
                transitionLabel: isTrackChange
                    ? "changing AirPlay tracks"
                    : "moving playback to AirPlay",
                attemptID: UUID(),
                details: details,
                ratingKey: ratingKey,
                media: details.media[mediaIndex],
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
            stopTranscodeSessionInBackground(newTranscodeSessionID, serverID: activePlaybackServerID)
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
    func activateReplacementAttempt(
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
        shouldAutoPlay: Bool = true,
        audioTrackPositionOverride: Int? = nil,
        audioChannelCountOverride: Int? = nil
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
        newEngine.applySubtitleFontSize(preferences.subtitleFontSize)
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
        // A quality/fallback switch can change the delivered dynamic range (a
        // server transcode of an HDR source lands as SDR), so the criteria is
        // re-evaluated rather than carried over from the previous attempt.
        let dolbyVisionRemux = remuxDolbyVisionConfiguration(for: media, decision: playbackDecision)
        // VLCKit can take over a remux URL (external subtitle mount); it
        // plays the copy as is, so there is nothing to convert.
        let dolbyVision7Conversion = engineType == .avPlayer
            ? remuxDolbyVision7Conversion(for: media, decision: playbackDecision)
            : nil
        DisplayModeMatcher.apply(
            media: media,
            part: part,
            decision: playbackDecision,
            dolbyVision: dolbyVision7Conversion ?? dolbyVisionRemux
        )
        engine = newEngine
        remuxTrackSelection = playbackDecision.isSpatialAudio
            ? ExplicitTrackSelection(audioStreamID: activeAudioStreamID, subtitleStreamID: activeSubtitleStreamID)
            : nil
        let preferredAudioTrackPosition: Int? = switch playbackDecision {
        case .directPlay, .localDownload:
            audioTrackPositionOverride ?? PlayerViewModel.preferredAudioStreamPosition(
                inPart: part,
                preferredLanguage: preferences.defaultAudioLanguage
            )
        case .transcode, .serverStream, .spatialAudio, .airPlay, .liveTV:
            // HLS rewrites the stream layout; positions no longer apply.
            nil
        }
        playbackSource = PlaybackSource(
            url: playbackURL,
            startPosition: startPosition,
            shouldAutoPlay: shouldAutoPlay,
            context: attemptContext,
            preferredAudioTrackPosition: preferredAudioTrackPosition,
            preferredAudioChannelCount: audioChannelCountOverride ?? PlayerViewModel.preferredAudioStreamChannelCount(
                inPart: part,
                preferredLanguage: preferences.defaultAudioLanguage
            ),
            locality: sourceLocality(for: playbackURL, serverID: activePlaybackServerID),
            restoresDolbyAtmos: playbackDecision.isSpatialAudio && activeAudioStreamIsDolbyAtmos(in: part),
            dolbyVisionRemux: dolbyVisionRemux,
            dolbyVision7Conversion: dolbyVision7Conversion
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
        if case .localDownload = playbackDecision {
            activePlaybackUsesLocalDownload = true
        } else {
            activePlaybackUsesLocalDownload = false
        }
        playerPresentationID = UUID()
        nowPlayingController.beginSession(
            details: details,
            engine: newEngine,
            plexService: plexService,
            skipBackwardInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
            skipForwardInterval: preferences.playerDoubleTapForwardInterval.timeInterval
        )
        sharePlayController.playbackItemDidChange(
            activity: currentSharePlayActivity,
            engine: newEngine
        )

        if playbackDecision.isDirectPlay || playbackDecision.isSpatialAudio {
            // Returning to Original direct play re-arms the ladder watch; a
            // rebuilt Atmos remux re-arms its fallback to direct play.
            startDirectPlayFallbackWatch()
        }
    }

    #if os(tvOS)
    /// Reuses the same source/session; only the renderer changes. Once on VLC,
    /// leave it there for the item so subtitle Off/On never causes more reloads.
    func switchToVLCKitForEnhancedSubtitlesIfNeeded() {
        guard !didFinalizeCurrentSession, !isSwitchingQuality, !isPreparingAirPlay,
              activeLiveTVContext == nil,
              let details = activeItemDetails, let ratingKey, let debugInfo,
              debugInfo.engine == .avPlayer,
              let playbackSource, let currentEngine = engine else { return }
        switch debugInfo.decision {
        case .directPlay, .localDownload: break
        default: return
        }
        let decision = StreamResolver.evaluateForDirectPlayback(
            media: debugInfo.media,
            part: debugInfo.part,
            enhancementMode: preferences.videoEnhancementMode,
            selectedSubtitleStreamID: activeSubtitleStreamID,
            forceAVPlayer: preferences.forceAVPlayer,
            forceVLCKit: preferences.forceVLCKit
        )
        guard decision.usesEnhancedSubtitleRenderer else { return }

        let audioStreams = debugInfo.part.streams.filter { $0.streamType == .audio }
        let audioPosition = audioStreams.firstIndex { $0.id == activeAudioStreamID }
        pendingExplicitTrackSelection = ExplicitTrackSelection(
            audioStreamID: activeAudioStreamID,
            subtitleStreamID: activeSubtitleStreamID
        )
        // Prefer the live clock, including seeks behind the original resume
        // offset. A not-yet-ready engine still needs its pending resume offset.
        let resumePosition = currentEngine.state == .playing || currentEngine.state == .paused
            ? currentEngine.currentTime
            : max(currentEngine.currentTime, playbackSource.startPosition ?? 0)
        let shouldAutoPlay: Bool = switch currentEngine.state {
        case .playing: true
        case .paused: false
        default: playbackSource.shouldAutoPlay
        }
        activateReplacementAttempt(
            transitionLabel: "switching to VLCKit for enhanced SDR subtitles",
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: debugInfo.media,
            part: debugInfo.part,
            playbackURL: playbackSource.url,
            sanitizedURL: debugInfo.sanitizedPlaybackURL,
            playbackDecision: debugInfo.decision,
            engineType: .vlcKit,
            resolverReason: decision.reason,
            videoEnhancementRequest: VideoEnhancementRequest.make(
                mode: preferences.videoEnhancementMode, media: debugInfo.media, part: debugInfo.part
            ),
            startPosition: resumePosition,
            shouldAutoPlay: shouldAutoPlay,
            audioTrackPositionOverride: audioPosition,
            audioChannelCountOverride: audioPosition.flatMap { audioStreams[$0].channels }
        )
    }
    #endif

    // MARK: - External (sidecar) subtitles

    /// Re-reads the playing item after Plex installed a sidecar subtitle, so
    /// the new stream reaches the player's subtitle picker and gets selected.
    ///
    /// The active part snapshot (`debugInfo.part`, what the player hands to
    /// `PlayerViewModel.configureAutomaticTrackSelection`) is replaced with the
    /// refetched one; the newly appeared stream is then either mounted on the
    /// live VLCKit engine, handed to Plex for a server-rendered session, or
    /// reached by restarting the session on VLCKit. Returns the stream id it
    /// settled on, or nil when nothing new appeared (or nothing is playing).
    @discardableResult
    func refreshSubtitleStreamsAfterDownload(selectingStreamID: Int? = nil) async -> Int? {
        guard !didFinalizeCurrentSession,
              let ratingKey,
              let debugInfo else {
            return nil
        }

        let expectedPresentationID = playerPresentationID
        let previousSubtitleStreamIDs = Set(
            debugInfo.part.streams.filter { $0.streamType == .subtitle }.map(\.id)
        )

        let details: PlexMediaDetails
        do {
            details = try await plexService.getMediaDetails(
                ratingKey: ratingKey,
                serverID: activePlaybackServerID
            )
        } catch {
            playbackSessionLogger.error(
                "Subtitle refresh failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        // The session may have been torn down or replaced while awaiting Plex.
        guard !didFinalizeCurrentSession,
              self.ratingKey == ratingKey,
              playerPresentationID == expectedPresentationID else {
            return nil
        }

        guard var media = details.media.first(where: { $0.id == debugInfo.media.id }) ?? details.media.first,
              var part = media.parts.first(where: { $0.id == debugInfo.part.id }) ?? media.parts.first else {
            return nil
        }

        if activePlaybackUsesLocalDownload,
           let converted = downloadManager?.record(
               for: PlexItemID(serverID: activePlaybackServerID, ratingKey: ratingKey)
           )?.convertedMediaVersion(sourcePart: part),
           converted.part.id == debugInfo.part.id {
            // The server still describes the original file; only its sidecars
            // carry over to the local conversion (see convertedMediaVersion).
            media = converted.media
            part = converted.part
        }

        activeItemDetails = details
        self.debugInfo = PlaybackDebugInfo(
            title: debugInfo.title,
            engine: debugInfo.engine,
            decision: debugInfo.decision,
            media: media,
            part: part,
            attemptID: debugInfo.attemptID,
            resolverReason: debugInfo.resolverReason,
            sanitizedPlaybackURL: debugInfo.sanitizedPlaybackURL
        )

        let subtitleStreams = part.streams.filter { $0.streamType == .subtitle }
        let addedStreamID = selectingStreamID
            ?? subtitleStreams.first(where: { $0.key != nil && !previousSubtitleStreamIDs.contains($0.id) })?.id
            ?? subtitleStreams.first(where: { !previousSubtitleStreamIDs.contains($0.id) })?.id

        guard let addedStreamID else {
            // Still republish the part so the picker reflects the refetch.
            externalSubtitleRefreshToken = UUID()
            return nil
        }

        playbackSessionLogger.notice(
            "Subtitle refresh for ratingKey \(ratingKey, privacy: .public) picked up stream \(addedStreamID, privacy: .public)"
        )

        rememberShowTrackChoice(type: .subtitle, streamID: addedStreamID)
        if usesServerTrackSelection {
            // Server-rendered sessions (AirPlay burns subtitles in, the Atmos
            // remux carries them as WebVTT), so the id goes to Plex and the
            // HLS session is rebuilt around it.
            pendingExternalSubtitleStreamID = nil
            selectPlexStreamsForPlayback(
                audioStreamID: activeAudioStreamID,
                subtitleStreamID: addedStreamID
            )
            return addedStreamID
        }

        activeSubtitleStreamID = addedStreamID
        pendingExternalSubtitleStreamID = addedStreamID
        if engine?.supportsExternalSubtitles == true {
            externalSubtitleRefreshToken = UUID()
        } else {
            switchToVLCKitForExternalSubtitle(streamID: addedStreamID)
        }
        return addedStreamID
    }

    /// Restarts the live session on VLCKit at the current position so a Plex
    /// sidecar subtitle can be mounted. AVPlayer cannot attach one to an
    /// existing item, so the engine — not the delivery rung — is what changes:
    /// the same URL, media version, and decision are carried over.
    func switchToVLCKitForExternalSubtitle(streamID: Int) {
        guard !didFinalizeCurrentSession,
              !isSwitchingQuality,
              !isPreparingAirPlay,
              !isAirPlaySession,
              !activePlaybackUsesLocalDownload,
              activeLiveTVContext == nil,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              let playbackSource,
              engine?.supportsExternalSubtitles != true else {
            return
        }

        // The engine's clock may not have passed its resume seek yet, so keep
        // the best position any of the three sources knows about.
        let resumePosition = max(
            engine?.currentTime ?? 0,
            TimeInterval(lastReportedTimeMs) / 1000.0,
            playbackSource.startPosition ?? 0
        )
        let wasPlaying = engine?.state != .paused

        pendingExternalSubtitleStreamID = streamID
        activeSubtitleStreamID = streamID

        activateReplacementAttempt(
            transitionLabel: "switching to VLCKit to mount an external subtitle",
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: debugInfo.media,
            part: debugInfo.part,
            playbackURL: playbackSource.url,
            sanitizedURL: debugInfo.sanitizedPlaybackURL,
            playbackDecision: debugInfo.decision,
            engineType: .vlcKit,
            resolverReason: "External subtitle selected; VLCKit mounts Plex sidecar files",
            videoEnhancementRequest: .disabled,
            startPosition: resumePosition,
            shouldAutoPlay: wasPlaying
        )
    }

    /// Downloads play from disk; everything else inherits the locality of the
    /// session's server connection (LAN vs remote/relay). VLCKit sizes its
    /// protective caching — and with it the silent stretch before audio joins
    /// at start and after seeks — from this.
    func sourceLocality(for url: URL, serverID: String?) -> PlaybackSourceLocality {
        if url.isFileURL { return .localFile }
        let connection = plexService.pool.connection(for: serverID)
        return connection?.isLocal == true ? .localNetwork : .remoteNetwork
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
        let failedPresentationID = playerPresentationID
        defer {
            // A replacement remux/direct-play attempt arms its own watch.
            // The outgoing attempt must not clear its successor's flags and
            // expose an intermediate decoder error during the next recovery.
            if playerPresentationID == failedPresentationID {
                isAutomaticDirectPlayFallbackAvailable = false
                isAutomaticDirectPlayFallbackActive = false
            }
        }

        // A failed Dolby Vision 7 → 8.1 conversion first retries the same
        // remux without it (the HDR10 base layer). If that fails too, the
        // suppressed conversion lets the branch below leave for direct play.
        // When the retry cannot even start, that branch runs right away.
        if debugInfo?.decision.isSpatialAudio == true, playbackSource?.dolbyVision7Conversion != nil {
            let failureDescription = engine?.error?.errorDescription ?? "engine reported state .error"
            isDolbyVision7ConversionSuppressed = true
            if await retryRemuxWithoutDolbyVision7Conversion(failureDescription: failureDescription) {
                return
            }
            playbackSessionLogger.error(
                "Could not retry the remux without Dolby Vision 7 conversion for ratingKey \(self.ratingKey ?? "unknown", privacy: .public); continuing down the fallback ladder"
            )
        }

        // A failed Dolby Vision profile 5 remux goes down to the server
        // stream like direct play would: plain direct play is what cannot
        // render it in the first place.
        let isFailedDolbyVisionRemux = debugInfo.map {
            $0.decision.isSpatialAudio && StreamResolver.isDolbyVisionProfile5($0.media)
        } ?? false
        if debugInfo?.decision.isSpatialAudio == true, !isFailedDolbyVisionRemux {
            let failureDescription = engine?.error?.errorDescription ?? "engine reported state .error"
            await leaveSpatialAudioRemux(
                reason: "Spatial-audio remux failed (\(failureDescription)); automatic direct-play fallback",
                keepsExplicitTracks: false
            )
            return
        }

        guard !didFinalizeCurrentSession,
              !activePlaybackUsesLocalDownload,
              !isSwitchingQuality,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              debugInfo.decision.isDirectPlay || isFailedDolbyVisionRemux,
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
                transcodeSessionID: transcodeSessionID,
                serverID: activePlaybackServerID
            )

            // The session may have been torn down or replaced while awaiting
            // the server's decision.
            guard !didFinalizeCurrentSession,
                  playerPresentationID == expectedPresentationID,
                  self.ratingKey == ratingKey else {
                stopTranscodeSessionInBackground(transcodeSessionID, serverID: activePlaybackServerID)
                return
            }

            guard case .transcodeAvailable = result.outcome else {
                playbackSessionLogger.error(
                    "Server-stream fallback unavailable for ratingKey \(ratingKey, privacy: .public) (outcome \(String(describing: result.outcome), privacy: .public)); leaving the error surface in place"
                )
                return
            }

            if let failedRemuxSessionID = activeTranscodeSessionID {
                stopTranscodeSessionInBackground(failedRemuxSessionID, serverID: activePlaybackServerID)
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
    func stopTranscodeSessionInBackground(_ transcodeSessionID: String, serverID: String?) {
        Task {
            await plexService.stopTranscodeSession(
                transcodeSessionID: transcodeSessionID,
                serverID: serverID
            )
        }
    }

    func handlePlaybackEnded() async {
        guard !isHandlingPlaybackEnded else { return }
        guard upNextPresentation == nil else { return }
        isHandlingPlaybackEnded = true
        defer { isHandlingPlaybackEnded = false }
        noteActivePlaybackState(.stopped)

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
        sharePlayController.leave()
        showPlayer = false
    }

    func finalizeCurrentPlaybackSession(markCompleted: Bool) {
        guard !didFinalizeCurrentSession else { return }
        didFinalizeCurrentSession = true
        noteActivePlaybackState(.stopped)

        timelineTimer?.invalidate()
        timelineTimer = nil
        airPlayTransitionTask?.cancel()
        airPlayTransitionTask = nil
        spatialAudioTransitionTask?.cancel()
        spatialAudioTransitionTask = nil
        isPreparingAirPlay = false
        cancelDirectPlayFallbackWatch()

        // Plex session hygiene: release the server transcoder with the session.
        if let transcodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(transcodeSessionID, serverID: activePlaybackServerID)
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
                    let serverID = activePlaybackServerID
                    Task {
                        try? await plexService.scrobble(ratingKey: ratingKey, serverID: serverID)
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
        spatialAudioTransitionTask?.cancel()
        spatialAudioTransitionTask = nil
        isPreparingAirPlay = false
        upNextPresentation = nil
        upNextPoster = nil
        clearAdjacentEpisodes()
        spentAutoSkipMarkerIDs = []
        resolvedIntroFingerprintMarkerIDs = []
        introOpeningSessionState = IntroOpeningSessionState()
        engine?.onPlaybackEnded = nil
        engine?.setPictureInPictureDelegate(nil)
        nowPlayingController.endSession()
        // Hand the display back to the system mode so the UI is not left running
        // at the content's refresh rate.
        DisplayModeMatcher.reset()
        engine = nil
        // Normally already stopped by finalize; belt-and-braces for paths
        // that clear without finalizing.
        if let transcodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(transcodeSessionID, serverID: activePlaybackServerID)
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
        remuxTrackSelection = nil
        pendingExternalSubtitleStreamID = nil
        activeShowTrackScope = nil
        pendingExplicitTrackSelection = nil
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
        noteActivePlaybackState(.idle)
    }

    func presentQualitySwitchError(_ message: String) {
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
