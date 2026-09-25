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
    }

    var isSpatialAudioSession: Bool {
        debugInfo?.decision.isSpatialAudio == true
    }

    /// Sessions whose audio/subtitle tracks are chosen by Plex (and changed by
    /// rebuilding the HLS session) rather than by the local engine.
    var usesServerTrackSelection: Bool {
        isAirPlaySession || isSpatialAudioSession
    }

    /// Asks Plex for a lossless remux around the given streams and returns it
    /// only when the file qualifies and Plex confirms video and audio are both
    /// copied. Every other outcome returns nil (and releases any session Plex
    /// started) so the caller keeps plain direct play.
    func requestSpatialAudioRemux(
        ratingKey: String,
        mediaIndex: Int,
        media: PlexMedia,
        part: PlexMediaPart,
        audioStreamID: Int?,
        subtitleStreamID: Int?,
        convertsAudio: Bool = false,
        sessionIdentifier: String,
        serverID: String?
    ) async -> SpatialAudioRemux? {
        // Audio conversion is the undecodable-audio fallback, not a spatial
        // audio preference, so the setting only gates the Dolby remux.
        guard preferences.spatialAudioRemuxEnabled || convertsAudio,
              !preferences.forceAVPlayer,
              !preferences.forceVLCKit else {
            return nil
        }

        let resolverDecision = StreamResolver.evaluate(media: media)
        let audioStream = part.streams.first { $0.streamType == .audio && $0.id == audioStreamID }
        let subtitleStream = subtitleStreamID.flatMap { id in
            part.streams.first { $0.streamType == .subtitle && $0.id == id }
        }
        if let blocker = StreamResolver.spatialAudioRemuxBlocker(
            media: media,
            decision: resolverDecision,
            audioStream: audioStream,
            subtitleStream: subtitleStream,
            displaySupportsHDR: AVPlayer.eligibleForHDRPlayback,
            convertsAudio: convertsAudio
        ) {
            spatialAudioLogger.notice(
                "No spatial-audio remux for ratingKey \(ratingKey, privacy: .public): \(blocker, privacy: .public)"
            )
            return nil
        }

        // Plex builds a session's subtitle from the part's server-side
        // selection, so mirror the choice there first (as Plex's own clients
        // do on a track change). Only touched when it actually differs.
        let selectedAudioID = part.streams.first { $0.streamType == .audio && ($0.isSelected ?? false) }?.id
        let selectedSubtitleID = part.streams.first { $0.streamType == .subtitle && ($0.isSelected ?? false) }?.id
        if selectedAudioID != audioStreamID || selectedSubtitleID != subtitleStreamID {
            do {
                try await plexService.selectStreams(
                    partID: part.id,
                    audioStreamID: audioStreamID,
                    subtitleStreamID: subtitleStreamID ?? 0,
                    serverID: serverID
                )
            } catch {
                spatialAudioLogger.error(
                    "Could not record stream selection for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public); keeping direct play"
                )
                return nil
            }
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
            let acceptsStreams = convertsAudio
                ? result.streams.isVideoCopyRemux
                : result.streams.isLosslessRemux
            guard case .transcodeAvailable = result.outcome,
                  acceptsStreams,
                  subtitleStreamID == nil || result.streams.subtitleLocation == "segments-subs" else {
                stopTranscodeSessionInBackground(transcodeSessionID, serverID: serverID)
                spatialAudioLogger.notice(
                    "Plex declined a lossless spatial-audio remux for ratingKey \(ratingKey, privacy: .public) (outcome \(String(describing: result.outcome), privacy: .public), \(result.streams.logDescription, privacy: .public)); keeping direct play"
                )
                return nil
            }

            spatialAudioLogger.notice(
                "Spatial-audio remux accepted for ratingKey \(ratingKey, privacy: .public): \(result.streams.logDescription, privacy: .public)"
            )
            let reason: String
            if convertsAudio {
                let source = audioStream?.codec?.uppercased() ?? "audio"
                let target = result.streams.audioCodec?.uppercased() ?? "a supported codec"
                reason = "\(source) converted to \(target) by Plex, video copied (\(resolverDecision.reason))"
            } else {
                let audioLabel = audioStream.map { StreamResolver.isDolbyAtmos($0) ? "Dolby Atmos" : "multichannel Dolby" } ?? "Dolby"
                reason = "\(audioLabel) via lossless Plex remux (\(resolverDecision.reason))"
            }
            return SpatialAudioRemux(
                url: result.url,
                transcodeSessionID: transcodeSessionID,
                reason: reason
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
            await self?.rebuildSpatialAudioSessionForTrackChange()
        }
    }

    private func rebuildSpatialAudioSessionForTrackChange() async {
        guard isSpatialAudioSession,
              !isSwitchingQuality,
              !didFinalizeCurrentSession,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first else {
            return
        }

        let media = details.media[mediaIndex]
        let playbackSessionID = activePlaybackSessionIdentifier ?? UUID().uuidString
        activePlaybackSessionIdentifier = playbackSessionID
        let expectedPresentationID = playerPresentationID
        let audioStreamID = activeAudioStreamID
        let subtitleStreamID = activeSubtitleStreamID
        let audioCodec = part.streams.first { $0.streamType == .audio && $0.id == audioStreamID }?.codec

        let remux = await requestSpatialAudioRemux(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            media: media,
            part: part,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            convertsAudio: PlayerViewModel.isLocallyUndecodableAudioCodec(audioCodec),
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
            return
        }

        guard let remux else {
            await leaveSpatialAudioRemux(
                reason: "Selected tracks cannot ride the spatial-audio remux; direct play",
                keepsExplicitTracks: true
            )
            return
        }

        let wasPlaying = engine?.state != .paused
        let resumePosition = currentResumePosition
        if let oldTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(oldTranscodeSessionID, serverID: activePlaybackServerID)
        }
        activeTranscodeSessionID = remux.transcodeSessionID
        activateReplacementAttempt(
            transitionLabel: "rebuilding the spatial-audio remux for selected tracks",
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
              let part = details.media[mediaIndex].parts.first,
              let directPlayURL = plexService.directPlayURL(for: part, serverID: activePlaybackServerID) else {
            return
        }

        let media = details.media[mediaIndex]
        let resolverDecision = StreamResolver.evaluate(
            media: media,
            forceAVPlayer: preferences.forceAVPlayer,
            forceVLCKit: preferences.forceVLCKit
        )
        let wasPlaying = engine?.state != .paused && engine?.state != .error
        let resumePosition = currentResumePosition

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
            audioTrackPositionOverride: audioTrackPosition
        )
    }

    /// Whether the remux's audio is E-AC-3 + JOC. Only then does the session
    /// go through `RemuxHLSLoader`: claiming Atmos for a plain 5.1 E-AC-3
    /// track would mislabel it to the decoder (and to an HDMI receiver).
    func activeAudioStreamIsDolbyAtmos(in part: PlexMediaPart) -> Bool {
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

/// Plex stream ids the viewer explicitly chose, carried across an engine swap
/// so the new engine opens on them instead of re-running automatic selection.
/// `subtitleStreamID == nil` means subtitles off.
struct ExplicitTrackSelection: Sendable, Equatable {
    let audioStreamID: Int?
    let subtitleStreamID: Int?
}
