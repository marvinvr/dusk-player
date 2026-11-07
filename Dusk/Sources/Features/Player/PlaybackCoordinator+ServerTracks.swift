import Foundation

extension PlaybackCoordinator {
    var isAV1ServerSession: Bool {
        guard let debugInfo, case .serverStream = debugInfo.decision else { return false }
        return StreamResolver.containsAV1(debugInfo.media)
    }

    func scheduleServerStreamTrackChange() {
        let previous = spatialAudioTransitionTask
        previous?.cancel()
        spatialAudioTransitionTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.rebuildServerStreamSession(reason: "Plex server track selection changed")
        }
    }

    /// HLS contains only the server-selected streams. Rebuild it for track
    /// changes (including bitmap burn-in and Off), retaining manual quality.
    /// AV1 decoder fallback uses the same flow with uncapped conversion.
    func rebuildServerStreamSession(reason: String) async {
        guard !didFinalizeCurrentSession, !activePlaybackUsesLocalDownload,
              !isSwitchingQuality,
              let details = activeItemDetails, let debugInfo, let ratingKey,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }) else { return }
        isSwitchingQuality = true
        defer { isSwitchingQuality = false }
        let previousSelection = remuxTrackSelection
        let presentationID = playerPresentationID
        let sessionID = UUID().uuidString
        let serverID = activePlaybackServerID
        let position = max(0, engine?.currentTime ?? playbackSource?.startPosition ?? TimeInterval(lastReportedTimeMs) / 1000.0)
        let wasPlaying = engine?.state != .paused
        let playbackDecision: PlaybackDecision = isPlexServerStreamSession ? debugInfo.decision : .serverStream
        let engineType: PlaybackEngineType = isPlexServerStreamSession ? debugInfo.engine : .avPlayer
        do {
            try await plexService.selectStreams(
                partID: debugInfo.part.id, audioStreamID: activeAudioStreamID,
                subtitleStreamID: activeSubtitleStreamID ?? 0, serverID: serverID
            )
            let result: (url: URL, outcome: PlexService.TranscodeDecisionOutcome)
            if case let .transcode(preset) = debugInfo.decision {
                result = try await plexService.transcodeURL(
                    ratingKey: ratingKey, mediaIndex: mediaIndex, preset: preset,
                    sessionIdentifier: activePlaybackSessionIdentifier ?? UUID().uuidString,
                    transcodeSessionID: sessionID, audioStreamID: activeAudioStreamID,
                    subtitleStreamID: activeSubtitleStreamID, serverID: serverID
                )
            } else {
                result = try await plexService.serverStreamURL(
                    ratingKey: ratingKey, mediaIndex: mediaIndex,
                    sessionIdentifier: activePlaybackSessionIdentifier ?? UUID().uuidString,
                    transcodeSessionID: sessionID, audioStreamID: activeAudioStreamID,
                    subtitleStreamID: activeSubtitleStreamID,
                    forceVideoTranscode: StreamResolver.containsAV1(debugInfo.media), serverID: serverID
                )
            }
            guard !Task.isCancelled, !didFinalizeCurrentSession,
                  playerPresentationID == presentationID else {
                stopTranscodeSessionInBackground(sessionID, serverID: serverID)
                return
            }
            guard case .transcodeAvailable = result.outcome else {
                stopTranscodeSessionInBackground(sessionID, serverID: serverID)
                if let previousSelection {
                    activeAudioStreamID = previousSelection.audioStreamID
                    activeSubtitleStreamID = previousSelection.subtitleStreamID
                }
                presentQualitySwitchError("Plex could not prepare the selected tracks.")
                return
            }
            if let previous = activeTranscodeSessionID {
                stopTranscodeSessionInBackground(previous, serverID: serverID)
            }
            activeTranscodeSessionID = sessionID
            remuxAudioConversion = nil
            activateReplacementAttempt(
                transitionLabel: reason, attemptID: UUID(), details: details, ratingKey: ratingKey,
                media: debugInfo.media, part: debugInfo.part, playbackURL: result.url,
                sanitizedURL: plexService.sanitizedPlaybackURLString(for: result.url),
                playbackDecision: playbackDecision, engineType: engineType, resolverReason: reason,
                videoEnhancementRequest: .disabled, startPosition: position, shouldAutoPlay: wasPlaying
            )
        } catch {
            stopTranscodeSessionInBackground(sessionID, serverID: serverID)
            if !Task.isCancelled, playerPresentationID == presentationID {
                if let previousSelection {
                    activeAudioStreamID = previousSelection.audioStreamID
                    activeSubtitleStreamID = previousSelection.subtitleStreamID
                }
                presentQualitySwitchError(error.localizedDescription)
            }
        }
    }
}
