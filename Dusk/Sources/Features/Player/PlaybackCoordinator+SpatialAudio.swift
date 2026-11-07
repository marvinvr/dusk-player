import AVFoundation
import Foundation
import OSLog

private let spatialAudioLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "SpatialAudio"
)

/// Dolby Atmos / spatial-audio delivery for files only VLCKit could direct
/// play. VLCKit decodes Dolby audio to plain PCM, which drops Atmos objects
/// and never reaches AirPods spatial audio; AVPlayer renders both. Plex copies
/// the original video and audio into fMP4 HLS (no re-encode), the session
/// plays on AVPlayer, and `RemuxHLSLoader` restores the Atmos
/// signaling Plex's muxer drops. See docs/playback.md → "Dolby Atmos and
/// spatial audio".
extension PlaybackCoordinator {
    struct SpatialAudioRemux {
        let url: URL
        let transcodeSessionID: String
        let reason: String
        /// Plex converts the audio (instead of copying it) in this remux.
        let convertsAudio: Bool
        let restoresDolbyAtmos: Bool
    }

    var isSpatialAudioSession: Bool {
        debugInfo?.decision.isSpatialAudio == true
    }

    /// Sessions whose audio/subtitle tracks are chosen by Plex (and changed by
    /// rebuilding the HLS session) rather than by the local engine.
    var usesServerTrackSelection: Bool {
        isAirPlaySession || isSpatialAudioSession || isPlexServerStreamSession
    }

    var isPlexServerStreamSession: Bool {
        switch debugInfo?.decision {
        case .serverStream, .transcode: true
        default: false
        }
    }

    /// Requests a copy-remux, or video copied with E-AC-3 audio conversion.
    /// Validates Plex's container/codecs before loading an engine. A declined
    /// decision releases the server session and keeps plain direct play.
    ///
    /// Dolby Vision profile 5 files take the same remux for their video
    /// (AVPlayer renders DV5 from MP4; libvlc cannot) regardless of the
    /// spatial-audio setting, and have Plex convert any audio the fMP4 cannot
    /// carry instead of refusing. Other HDR files (HDR10, HDR10+, HLG, Dolby
    /// Vision 7/8) take it when `hdrVideoRemuxEnabled` is on and the audio can
    /// be copied. DV7 + TrueHD instead requests audio conversion up front:
    /// picture wins over local lossless audio on that combination.
    func requestSpatialAudioRemux(
        ratingKey: String,
        mediaIndex: Int,
        media: PlexMedia,
        part: PlexMediaPart,
        audioStreamID: Int?,
        subtitleStreamID: Int?,
        convertsAudio: Bool = false,
        restoresServerSelection: Bool = false,
        sessionIdentifier: String,
        serverID: String?
    ) async -> SpatialAudioRemux? {
        let isAV1Remux = StreamResolver.canRemuxAV1(media)
        let isDolbyVisionRemux = StreamResolver.isDolbyVisionProfile5(media)
        let resolverDecision = StreamResolver.evaluate(media: media)
        let audioStream = part.streams.first { $0.streamType == .audio && $0.id == audioStreamID }
        if StreamResolver.containsAV1(media), !isAV1Remux { return nil }
        if isAV1Remux && !resolverDecision.requiresServerTranscode && !convertsAudio { return nil }
        let subtitleStream = subtitleStreamID.flatMap { id in
            part.streams.first { $0.streamType == .subtitle && $0.id == id }
        }
        // Picture wins for DV7 + TrueHD even when VLCKit decodes it. Decide
        // before the first Plex request, including on stock builds and track
        // changes, so no undecodable local/copy-only attempt precedes the remux.
        let convertsDV7TrueHD = audioStream.map {
            StreamResolver.convertedTrueHDRemuxBlocker(
                media: media,
                decision: resolverDecision,
                audioStream: $0,
                subtitleStream: subtitleStream,
                displaySupportsHDR: AVPlayer.eligibleForHDRPlayback,
                hdrVideoRemuxEnabled: preferences.hdrVideoRemuxEnabled
            ) == nil
        } ?? false
        let convertsAV1Audio = isAV1Remux && audioStream.map { !StreamResolver.canCopyAV1Audio($0) } == true
        let convertsAudio = convertsAudio || convertsDV7TrueHD || convertsAV1Audio
            || (isDolbyVisionRemux && audioStream.map { !StreamResolver.canCopyIntoRemux(audio: $0) } == true)
        // Audio conversion serves picture preservation/decoder recovery, so
        // it does not depend on the spatial-audio preference.
        let considersSpatialAudio = preferences.spatialAudioRemuxEnabled || convertsAudio
        let considersHDRVideo = preferences.hdrVideoRemuxEnabled
        guard considersSpatialAudio || considersHDRVideo || isDolbyVisionRemux || isAV1Remux,
              !preferences.forceAVPlayer,
              !preferences.forceVLCKit else {
            return nil
        }

        #if os(tvOS)
        // Enhanced SDR subtitles take priority over an optional Atmos copy
        // remux. Never veto a remux needed to decode audio or preserve HDR/DV.
        if !isAV1Remux, !convertsAudio, StreamResolver.evaluateForDirectPlayback(
            media: media,
            part: part,
            enhancementMode: preferences.videoEnhancementMode,
            selectedSubtitleStreamID: subtitleStreamID
        ).usesEnhancedSubtitleRenderer {
            return nil
        }
        #endif

        let blocker: String?
        // Which of the two non-DV5 reasons qualified, for the session reason.
        var qualifiesForSpatialAudio = false
        var qualifiesForHDRVideo = false
        if isAV1Remux {
            blocker = subtitleStream.map { StreamResolver.canRideRemux(subtitle: $0) } == false
                ? "selected subtitle requires video conversion" : nil
        } else if isDolbyVisionRemux {
            blocker = StreamResolver.dolbyVisionRemuxBlocker(
                media: media,
                subtitleStream: subtitleStream,
                displaySupportsHDR: AVPlayer.eligibleForHDRPlayback
            )
        } else {
            let spatialAudioBlocker = considersSpatialAudio
                ? StreamResolver.spatialAudioRemuxBlocker(
                    media: media,
                    decision: resolverDecision,
                    audioStream: audioStream,
                    subtitleStream: subtitleStream,
                    displaySupportsHDR: AVPlayer.eligibleForHDRPlayback,
                    convertsAudio: convertsAudio
                )
                : "Dolby Atmos remux is off"
            let hdrVideoBlocker = considersHDRVideo
                ? StreamResolver.hdrVideoRemuxBlocker(
                    media: media,
                    decision: resolverDecision,
                    audioStream: audioStream,
                    subtitleStream: subtitleStream,
                    displaySupportsHDR: AVPlayer.eligibleForHDRPlayback
                )
                : "HDR remux is off"
            qualifiesForSpatialAudio = spatialAudioBlocker == nil
            qualifiesForHDRVideo = hdrVideoBlocker == nil
            blocker = qualifiesForSpatialAudio || qualifiesForHDRVideo
                ? nil
                : [spatialAudioBlocker, hdrVideoBlocker].compactMap { $0 }.joined(separator: "; ")
        }
        if let blocker {
            spatialAudioLogger.notice(
                "No spatial-audio remux for ratingKey \(ratingKey, privacy: .public): \(blocker, privacy: .public)"
            )
            return nil
        }

        // Plex builds a session's subtitle from the part's server-side
        // selection, so mirror the choice there first (as Plex's own clients
        // do on a track change). Always write it: `part` is the startup
        // snapshot, so comparing its selection after On → Off → On skips
        // necessary updates. Zero explicitly clears Plex's subtitle choice.
        do {
            try await plexService.selectStreams(
                partID: part.id,
                audioStreamID: audioStreamID,
                subtitleStreamID: subtitleStreamID ?? 0,
                serverID: serverID
            )
            if restoresServerSelection {
                noteAutomaticServerSelectionWrite(
                    part: part, audioStreamID: audioStreamID,
                    subtitleStreamID: subtitleStreamID, serverID: serverID
                )
            }
        } catch {
            spatialAudioLogger.error(
                "Could not record stream selection for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public); declining remux"
            )
            return nil
        }

        let transcodeSessionID = UUID().uuidString
        do {
            let result = try await plexService.spatialAudioRemuxURL(
                ratingKey: ratingKey,
                mediaIndex: mediaIndex,
                sessionIdentifier: sessionIdentifier,
                transcodeSessionID: transcodeSessionID,
                audioStreamID: audioStreamID,
                subtitleStreamID: subtitleStreamID,
                convertsAudio: convertsAudio,
                serverID: serverID
            )
            let acceptsStreams: Bool
            if isAV1Remux {
                acceptsStreams = result.streams.container?.lowercased() == "mp4" &&
                    StreamResolver.isAV1Codec(result.streams.videoCodec) &&
                    result.streams.videoDecision == "copy" &&
                    (audioStream == nil || (convertsAudio
                        ? result.streams.isConvertedAudioRemux(sourceChannels: audioStream?.channels)
                        : result.streams.audioDecision == "copy"))
            } else {
                acceptsStreams = convertsAudio
                    ? result.streams.isConvertedAudioRemux(sourceChannels: audioStream?.channels)
                    : result.streams.isLosslessRemux
            }
            guard case .transcodeAvailable = result.outcome,
                  acceptsStreams,
                  subtitleStreamID == nil || result.streams.subtitleLocation == "segments-subs" else {
                stopTranscodeSessionInBackground(transcodeSessionID, serverID: serverID)
                spatialAudioLogger.notice(
                    "Plex declined a compatible spatial-audio remux for ratingKey \(ratingKey, privacy: .public) (outcome \(String(describing: result.outcome), privacy: .public), \(result.streams.logDescription, privacy: .public)); keeping direct play"
                )
                return nil
            }

            spatialAudioLogger.notice(
                "Spatial-audio remux accepted for ratingKey \(ratingKey, privacy: .public): \(result.streams.logDescription, privacy: .public)"
            )
            let reason: String
            if isAV1Remux {
                let audioNote = convertsAudio ? ", audio converted to E-AC-3" : ""
                reason = "AV1 hardware decode via Plex fMP4 remux (video copied\(audioNote))"
            } else if isDolbyVisionRemux {
                let audioNote = convertsAudio
                    ? ", \(audioStream?.codec?.uppercased() ?? "audio") converted to \(result.streams.audioCodec?.uppercased() ?? "a supported codec")"
                    : ""
                reason = "Dolby Vision profile 5 via lossless Plex remux\(audioNote)"
            } else if convertsAudio {
                let source = audioStream?.codec?.uppercased() ?? "audio"
                let target = result.streams.audioCodec?.uppercased() ?? "a supported codec"
                let videoNote = remuxDolbyVision7Conversion(for: media, decision: .spatialAudio) != nil
                    ? ", Dolby Vision 7 → 8.1 on device"
                    : ""
                reason = "\(source) converted to \(target) by Plex, video copied\(videoNote) (\(resolverDecision.reason))"
            } else {
                var labels: [String] = []
                if qualifiesForSpatialAudio {
                    labels.append(audioStream.map { StreamResolver.isDolbyAtmos($0) ? "Dolby Atmos" : "multichannel Dolby" } ?? "Dolby")
                }
                if remuxDolbyVision7Conversion(for: media, decision: .spatialAudio) != nil {
                    labels.append("Dolby Vision 7 → 8.1")
                } else if qualifiesForHDRVideo {
                    labels.append(StreamResolver.hdrVideoLabel(for: media))
                }
                reason = "\(labels.joined(separator: " + ")) via lossless Plex remux (\(resolverDecision.reason))"
            }
            return SpatialAudioRemux(
                url: result.url,
                transcodeSessionID: transcodeSessionID,
                reason: reason,
                convertsAudio: convertsAudio,
                restoresDolbyAtmos: result.streams.hasDolbyAtmosAudio
            )
        } catch {
            stopTranscodeSessionInBackground(transcodeSessionID, serverID: serverID)
            spatialAudioLogger.error(
                "Spatial-audio remux request failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public); keeping direct play"
            )
            return nil
        }
    }

    /// The viewer picked different tracks in a remux session: rebuild the
    /// remux around them, or — when the new combination cannot ride a
    /// lossless remux (TrueHD, AAC, a PGS subtitle, …) — move to plain direct
    /// play with exactly those tracks. Serialized like AirPlay transitions.
    func scheduleSpatialAudioTrackChange() {
        let previousTask = spatialAudioTransitionTask
        previousTask?.cancel()
        spatialAudioTransitionTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            await self?.rebuildSpatialAudioSession(
                transitionLabel: "rebuilding the spatial-audio remux for selected tracks",
                declineReason: "Selected tracks cannot ride the spatial-audio remux; direct play"
            )
        }
    }

    /// A failed Dolby Vision 7 → 8.1 session: rebuilds the same remux without
    /// the conversion (the caller has already suppressed it for this item).
    /// Queued behind any track-change rebuild in flight, so the two never
    /// race; one that already replaced the failed engine counts as the retry.
    /// Returns false only when no rebuild could start, so the caller can take
    /// the next rung of the ladder instead of leaving the error overlay up.
    func retryRemuxWithoutDolbyVision7Conversion(failureDescription: String) async -> Bool {
        let failedEngine = engine
        let previousTask = spatialAudioTransitionTask
        let retry = Task { @MainActor [weak self] () -> Bool in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return true }
            guard self.engine === failedEngine else { return true }
            return await self.rebuildSpatialAudioSession(
                transitionLabel: "retrying the remux without Dolby Vision 7 conversion (\(failureDescription))",
                declineReason: "Remux unavailable after Dolby Vision 7 conversion failed; direct play"
            )
        }
        // A track change picked meanwhile waits for this retry to land.
        spatialAudioTransitionTask = Task { _ = await retry.value }
        return await retry.value
    }

    /// Asks Plex for a fresh remux of the live item around the active tracks
    /// and swaps to it at the live position (the old transcode session is
    /// stopped). When Plex declines, moves to direct play with `declineReason`.
    /// Returns false when the session is not in a state to rebuild (nothing
    /// was requested); true once it ran, including when it was superseded.
    @discardableResult
    func rebuildSpatialAudioSession(transitionLabel: String, declineReason: String) async -> Bool {
        guard isSpatialAudioSession,
              !isSwitchingQuality,
              !didFinalizeCurrentSession,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first else {
            return false
        }

        let media = details.media[mediaIndex]
        let playbackSessionID = activePlaybackSessionIdentifier ?? UUID().uuidString
        activePlaybackSessionIdentifier = playbackSessionID
        let expectedPresentationID = playerPresentationID
        let audioStreamID = activeAudioStreamID
        let subtitleStreamID = activeSubtitleStreamID
        let audioCodec = part.streams.first { $0.streamType == .audio && $0.id == audioStreamID }?.codec
        // Keep converting when the remux being rebuilt already converts this
        // very stream (a subtitle change, the Dolby Vision 7 retry): TrueHD is
        // locally decodable on Dusk's VLCKit, so the codec alone would drop
        // the conversion and with it the remux (and HDR). A newly picked
        // decodable stream (TrueHD, DTS) still leaves for direct play.
        let keepsAudioConversion = remuxAudioConversion.map { $0.audioStreamID == audioStreamID } ?? false

        let remux = await requestSpatialAudioRemux(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            media: media,
            part: part,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            convertsAudio: keepsAudioConversion || PlayerViewModel.isLocallyUndecodableAudioCodec(audioCodec),
            sessionIdentifier: playbackSessionID,
            serverID: activePlaybackServerID
        )

        guard !Task.isCancelled,
              !didFinalizeCurrentSession,
              playerPresentationID == expectedPresentationID,
              self.ratingKey == ratingKey else {
            if let remux {
                stopTranscodeSessionInBackground(remux.transcodeSessionID, serverID: activePlaybackServerID)
            }
            return true
        }

        guard let remux else {
            await leaveSpatialAudioRemux(reason: declineReason, keepsExplicitTracks: true)
            return true
        }

        let wasPlaying = engine?.state != .paused
        let resumePosition = currentResumePosition
        if let oldTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(oldTranscodeSessionID, serverID: activePlaybackServerID)
        }
        activeTranscodeSessionID = remux.transcodeSessionID
        remuxAudioConversion = remux.convertsAudio
            ? RemuxAudioConversion(audioStreamID: audioStreamID, restoresDolbyAtmos: remux.restoresDolbyAtmos)
            : nil
        activateReplacementAttempt(
            transitionLabel: transitionLabel,
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: media,
            part: part,
            playbackURL: remux.url,
            sanitizedURL: plexService.sanitizedPlaybackURLString(for: remux.url),
            playbackDecision: .spatialAudio,
            engineType: .avPlayer,
            resolverReason: remux.reason,
            videoEnhancementRequest: .disabled,
            startPosition: resumePosition,
            shouldAutoPlay: wasPlaying
        )
        return true
    }

    /// Undecodable-audio fallback (TrueHD on VLCKit): restarts the session as
    /// a video-copy remux whose audio Plex converts (to 5.1 E-AC-3), on
    /// AVPlayer at the live position. Returns false when that is not possible
    /// so the caller can fall back to a full transcode. A bitmap subtitle
    /// cannot ride the remux and is dropped rather than forcing a video
    /// re-encode; picking one later moves the session to direct play.
    func playConvertedAudioRemux(audioStreamID: Int?) async -> Bool {
        guard !didFinalizeCurrentSession,
              !isSwitchingQuality,
              !isAirPlayPlaybackActive,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first else {
            return false
        }

        let media = details.media[mediaIndex]
        let subtitleStreamID = activeSubtitleStreamID.flatMap { id -> Int? in
            guard let stream = part.streams.first(where: { $0.streamType == .subtitle && $0.id == id }) else {
                return nil
            }
            return StreamResolver.canRideRemux(subtitle: stream) ? id : nil
        }
        let playbackSessionID = activePlaybackSessionIdentifier ?? UUID().uuidString
        activePlaybackSessionIdentifier = playbackSessionID
        let expectedPresentationID = playerPresentationID

        guard let remux = await requestSpatialAudioRemux(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            media: media,
            part: part,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            convertsAudio: true,
            sessionIdentifier: playbackSessionID,
            serverID: activePlaybackServerID
        ) else {
            return false
        }

        guard !didFinalizeCurrentSession,
              playerPresentationID == expectedPresentationID,
              self.ratingKey == ratingKey else {
            stopTranscodeSessionInBackground(remux.transcodeSessionID, serverID: activePlaybackServerID)
            return true
        }

        let wasPlaying = engine?.state != .paused
        let resumePosition = currentResumePosition
        if let oldTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(oldTranscodeSessionID, serverID: activePlaybackServerID)
        }
        activeTranscodeSessionID = remux.transcodeSessionID
        activeAudioStreamID = audioStreamID
        activeSubtitleStreamID = subtitleStreamID
        remuxAudioConversion = RemuxAudioConversion(
            audioStreamID: audioStreamID, restoresDolbyAtmos: remux.restoresDolbyAtmos
        )
        activateReplacementAttempt(
            transitionLabel: "converting undecodable audio on the server (video copied)",
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: media,
            part: part,
            playbackURL: remux.url,
            sanitizedURL: plexService.sanitizedPlaybackURLString(for: remux.url),
            playbackDecision: .spatialAudio,
            engineType: .avPlayer,
            resolverReason: remux.reason,
            videoEnhancementRequest: .disabled,
            startPosition: resumePosition,
            shouldAutoPlay: wasPlaying
        )
        return true
    }

    /// Moves a remux session to plain direct play (the resolver's engine) at
    /// the live position. With `keepsExplicitTracks`, the viewer's current
    /// Plex stream choices are carried over instead of re-running automatic
    /// selection; otherwise (a failed remux) the normal policy applies.
    func leaveSpatialAudioRemux(reason: String, keepsExplicitTracks: Bool) async {
        guard isSpatialAudioSession,
              !didFinalizeCurrentSession,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first else {
            return
        }

        let media = details.media[mediaIndex]
        if StreamResolver.containsAV1(media) {
            await rebuildServerStreamSession(reason: reason)
            return
        }
        // An unsupported track or a failed Plex request must not turn a
        // working HDR/DV remux into VLC direct play. In particular DV5 has
        // no compatible base layer and produces pink/green video in VLC.
        if keepsExplicitTracks, part.streams.contains(where: {
            $0.streamType == .video && ($0.isHDRVideo || StreamResolver.hdrTransfer(of: $0) != nil ||
                $0.doviPresent == true || $0.doviProfile != nil ||
                $0.doviBLCompatID != nil || $0.doviLevel != nil)
        }) {
            if let remuxTrackSelection {
                activeAudioStreamID = remuxTrackSelection.audioStreamID
                activeSubtitleStreamID = remuxTrackSelection.subtitleStreamID
            }
            presentQualitySwitchError("Couldn’t change tracks while preserving HDR video. Playback continues with the previous tracks.")
            return
        }
        guard let directPlayURL = plexService.directPlayURL(for: part, serverID: activePlaybackServerID) else {
            return
        }
        let resolverDecision = StreamResolver.evaluateForDirectPlayback(
            media: media,
            part: part,
            enhancementMode: preferences.videoEnhancementMode,
            selectedSubtitleStreamID: keepsExplicitTracks ? activeSubtitleStreamID : PlayerViewModel.preferredSubtitleStreamID(
                inPart: part,
                policy: SubtitleSelectionPolicy(preferences: preferences),
                audioStream: nil
            ),
            forceAVPlayer: preferences.forceAVPlayer,
            forceVLCKit: preferences.forceVLCKit
        )
        let wasPlaying = engine?.state != .paused && engine?.state != .error
        let resumePosition = resolverDecision.usesEnhancedSubtitleRenderer &&
            (engine?.state == .playing || engine?.state == .paused)
            ? engine?.currentTime ?? currentResumePosition
            : currentResumePosition

        var audioTrackPosition: Int?
        if keepsExplicitTracks {
            let audioStreams = part.streams.filter { $0.streamType == .audio }
            // Never open libvlc on a track it cannot decode (TrueHD): that is
            // a silent start. Automatic selection picks a decodable one.
            audioTrackPosition = audioStreams.firstIndex {
                $0.id == activeAudioStreamID && !PlayerViewModel.isLocallyUndecodableAudioCodec($0.codec)
            }
            pendingExplicitTrackSelection = ExplicitTrackSelection(
                audioStreamID: activeAudioStreamID,
                subtitleStreamID: activeSubtitleStreamID
            )
        } else {
            pendingExplicitTrackSelection = nil
        }

        if let oldTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(oldTranscodeSessionID, serverID: activePlaybackServerID)
        }
        activeTranscodeSessionID = nil
        remuxAudioConversion = nil
        spatialAudioLogger.notice(
            "Leaving spatial-audio remux for ratingKey \(ratingKey, privacy: .public): \(reason, privacy: .public)"
        )
        activateReplacementAttempt(
            transitionLabel: "leaving the spatial-audio remux for direct play",
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: media,
            part: part,
            playbackURL: directPlayURL,
            sanitizedURL: plexService.sanitizedPlaybackURLString(for: directPlayURL),
            playbackDecision: .directPlay,
            engineType: resolverDecision.engine,
            resolverReason: "\(reason) (\(resolverDecision.reason))",
            videoEnhancementRequest: VideoEnhancementRequest.make(
                mode: preferences.videoEnhancementMode,
                media: media,
                part: part
            ),
            startPosition: resumePosition,
            shouldAutoPlay: wasPlaying,
            audioTrackPositionOverride: audioTrackPosition,
            audioChannelCountOverride: resolverDecision.usesEnhancedSubtitleRenderer
                ? part.streams.first(where: { $0.streamType == .audio && $0.id == activeAudioStreamID })?.channels
                : nil
        )
    }

    /// The Dolby Vision signaling `RemuxHLSLoader` restores on a remux of a
    /// Dolby Vision profile 5 file, or of a profile 8.1/8.4 file while the
    /// HDR setting is on (any remux of it: HDR, Atmos or converted audio);
    /// nil for every other session.
    func remuxDolbyVisionConfiguration(
        for media: PlexMedia,
        decision: PlaybackDecision
    ) -> DolbyVisionConfiguration? {
        guard decision.isSpatialAudio else { return nil }
        return StreamResolver.dolbyVisionSignalingStream(
            in: media,
            includesProfile8: preferences.hdrVideoRemuxEnabled
        )
        .flatMap(DolbyVisionConfiguration.init(stream:))
    }

    /// The 8.1 configuration a remux of a Dolby Vision profile 7 file is
    /// converted to on device (`DolbyVision7HLSProxy`): any remux of it (HDR,
    /// Atmos or converted audio) while the HDR and conversion settings are
    /// on and the conversion has not failed for this item; nil otherwise.
    /// The single place that decides; extend it rather than checking elsewhere.
    func remuxDolbyVision7Conversion(
        for media: PlexMedia,
        decision: PlaybackDecision
    ) -> DolbyVisionConfiguration? {
        guard decision.isSpatialAudio,
              preferences.hdrVideoRemuxEnabled,
              preferences.dolbyVision7ConversionEnabled,
              !isDolbyVision7ConversionSuppressed else {
            return nil
        }
        return StreamResolver.dolbyVision7ConversionTarget(in: media)
    }

    /// Whether the remux's audio is E-AC-3 + JOC. Only then does the session
    /// go through `RemuxHLSLoader`: claiming Atmos for a plain 5.1 E-AC-3
    /// track would mislabel it to the decoder (and to an HDMI receiver).
    func activeAudioStreamIsDolbyAtmos(in part: PlexMediaPart) -> Bool {
        if let conversion = remuxAudioConversion, conversion.audioStreamID == activeAudioStreamID {
            return conversion.restoresDolbyAtmos
        }
        guard let stream = part.streams.first(where: {
            $0.streamType == .audio && $0.id == activeAudioStreamID
        }) else {
            return false
        }
        return StreamResolver.isDolbyAtmos(stream)
    }

    /// Hands the carried-over track choice to the player exactly once.
    func consumePendingExplicitTrackSelection() -> ExplicitTrackSelection? {
        defer { pendingExplicitTrackSelection = nil }
        return pendingExplicitTrackSelection
    }

    private var currentResumePosition: TimeInterval {
        max(
            engine?.currentTime ?? 0,
            TimeInterval(lastReportedTimeMs) / 1000.0,
            playbackSource?.startPosition ?? 0
        )
    }
}

/// The audio stream a remux session has Plex convert (see
/// `PlaybackCoordinator.remuxAudioConversion`).
struct RemuxAudioConversion: Sendable, Equatable {
    let audioStreamID: Int?
    var restoresDolbyAtmos = false
}

/// Plex stream ids the viewer explicitly chose, carried across an engine swap
/// so the new engine opens on them instead of re-running automatic selection.
/// `subtitleStreamID == nil` means subtitles off.
struct ExplicitTrackSelection: Sendable, Equatable {
    let audioStreamID: Int?
    let subtitleStreamID: Int?
}
