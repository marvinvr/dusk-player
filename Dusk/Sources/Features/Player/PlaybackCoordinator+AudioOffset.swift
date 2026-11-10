import Foundation

/// Manual audio sync (#67). The rules live in `AudioOffsetPolicy`; this
/// applies them to the live session.
extension PlaybackCoordinator {
    /// The facts `AudioOffsetPolicy` decides on, or nil without a library
    /// session (IPTV, pre-rolls, nothing loaded).
    var audioOffsetSession: AudioOffsetPolicy.Session? {
        guard let debugInfo, engine != nil else { return nil }
        return AudioOffsetPolicy.Session(
            engine: debugInfo.engine,
            decision: debugInfo.decision,
            containsHDRVideo: StreamResolver.containsHDRVideo(inPart: debugInfo.part),
            vlcKitCanDecodeVideo: !StreamResolver.containsAV1(debugInfo.media)
                || AV1PlaybackCapabilities.current.softwareDecode
        )
    }

    var audioOffsetAvailability: AudioOffsetPolicy.Availability {
        guard let session = audioOffsetSession else {
            return activeLiveTVContext != nil ? .liveTV : .unsupportedVideo
        }
        return AudioOffsetPolicy.availability(for: session)
    }

    func resetAudioOffset() {
        audioOffsetMilliseconds = 0
        isAudioOffsetPinnedToVLCKit = false
        reopensAudioOptionsAfterEngineSwitch = false
    }

    /// True once after the offset switch rebuilt the player.
    func consumeAudioOptionsReopen() -> Bool {
        defer { reopensAudioOptionsAfterEngineSwitch = false }
        return reopensAudioOptionsAfterEngineSwitch
    }

    /// Sets the offset for the item now playing: live on VLCKit; on AVPlayer a
    /// non-zero value restarts the item on VLCKit at the current position.
    /// A blocked or refused change leaves the previous value in place.
    func setAudioOffset(milliseconds requested: Int) {
        let milliseconds = AudioOffsetPolicy.clamped(requested)
        guard milliseconds != audioOffsetMilliseconds, let session = audioOffsetSession else { return }

        switch AudioOffsetPolicy.action(settingOffset: milliseconds, in: session) {
        case .blocked:
            return
        case .none:
            audioOffsetMilliseconds = milliseconds
        case .applyLive:
            audioOffsetMilliseconds = milliseconds
            engine?.setAudioDelay(milliseconds: milliseconds)
        case .switchToVLCKit:
            let previous = audioOffsetMilliseconds
            // Set first: the replacement engine picks it up before it loads.
            audioOffsetMilliseconds = milliseconds
            if !switchToVLCKitForAudioOffset() {
                audioOffsetMilliseconds = previous
            }
        }
    }

    /// Restarts the AVPlayer session on VLCKit at the current position — the
    /// same URL, media version and decision, like the external-subtitle
    /// switch — keeping the chosen tracks. Pins the item to VLCKit.
    private func switchToVLCKitForAudioOffset() -> Bool {
        guard !didFinalizeCurrentSession,
              !isSwitchingQuality,
              !isPreparingAirPlay,
              !isAirPlaySession,
              activeLiveTVContext == nil,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              debugInfo.engine == .avPlayer,
              let playbackSource,
              let currentEngine = engine else {
            return false
        }

        // Prefer the live clock, including seeks behind the original resume
        // offset; a not-yet-ready engine still needs its pending resume offset.
        let resumePosition = currentEngine.state == .playing || currentEngine.state == .paused
            ? currentEngine.currentTime
            : max(currentEngine.currentTime, TimeInterval(lastReportedTimeMs) / 1000.0, playbackSource.startPosition ?? 0)
        let shouldAutoPlay: Bool = switch currentEngine.state {
        case .playing: true
        case .paused: false
        default: playbackSource.shouldAutoPlay
        }

        let audioStreams = debugInfo.part.streams.filter { $0.streamType == .audio }
        let audioPosition = audioStreams.firstIndex { $0.id == activeAudioStreamID }
        pendingExplicitTrackSelection = ExplicitTrackSelection(
            audioStreamID: activeAudioStreamID,
            subtitleStreamID: activeSubtitleStreamID
        )
        // A Plex sidecar the AVPlayer session showed has to be mounted again.
        if let subtitleID = activeSubtitleStreamID,
           debugInfo.part.streams.contains(where: { $0.id == subtitleID && $0.key != nil }) {
            pendingExternalSubtitleStreamID = subtitleID
        }

        let videoEnhancementRequest: VideoEnhancementRequest = switch debugInfo.decision {
        case .directPlay, .localDownload:
            VideoEnhancementRequest.make(
                mode: preferences.videoEnhancementMode, media: debugInfo.media, part: debugInfo.part
            )
        default:
            .disabled
        }

        isAudioOffsetPinnedToVLCKit = true
        reopensAudioOptionsAfterEngineSwitch = true
        activateReplacementAttempt(
            transitionLabel: "switching to VLCKit for a manual audio offset",
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: debugInfo.media,
            part: debugInfo.part,
            playbackURL: playbackSource.url,
            sanitizedURL: debugInfo.sanitizedPlaybackURL,
            playbackDecision: debugInfo.decision,
            engineType: .vlcKit,
            resolverReason: "Audio offset set; only VLCKit can delay audio",
            videoEnhancementRequest: videoEnhancementRequest,
            startPosition: resumePosition,
            shouldAutoPlay: shouldAutoPlay,
            audioTrackPositionOverride: audioPosition,
            audioChannelCountOverride: audioPosition.flatMap { audioStreams[$0].channels }
        )
        return true
    }
}
