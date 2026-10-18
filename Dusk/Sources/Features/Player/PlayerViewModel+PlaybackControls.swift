import Foundation
import OSLog
import SwiftUI

extension PlayerViewModel {
    /// The HUD's fade curve. Used for both directions so revealing and hiding
    /// the controls are mirror images. `PlayerView` reads it too, so it cannot
    /// be private.
    static let controlsVisibilityAnimation: Animation = .easeInOut(duration: 0.125)
    private static let playPauseAnimation: Animation = .snappy(duration: 0.1)
    private static let pendingPlaybackStateGracePeriod: TimeInterval = 0.35
    private static let seekFeedbackDisplayDuration: Duration = .milliseconds(325)
    private static let markerSkipPadding: TimeInterval = 0.5
    private static let autoSkipCountdownDuration = IntroOpeningObservation.courtesyDelay
    private static let maximumAutoSkipCountdownTick: TimeInterval = 0.25
    private static let autoSkipCountdownPollingInterval: Duration = .milliseconds(50)
    private static let bufferingIndicatorDelay: TimeInterval = 2.0
    private static let stallRecoveryDelay: TimeInterval = 12.0
    private static let stallRecoveryCooldown: TimeInterval = 8.0
    private static let stallProgressTolerance: TimeInterval = 0.75
    private static let maxStallRecoveryAttempts = 2
    #if os(tvOS)
    /// tvOS tunables live together in `PlayerTVHUDLayout` so they can be
    /// adjusted in one on-device pass.
    private static let controlsAutoHideDelay: TimeInterval = PlayerTVHUDLayout.autoHideDelay
    #else
    private static let controlsAutoHideDelay: TimeInterval = 4.0
    #endif
    // The settings menu is a deliberate, multi-step interaction (open the menu,
    // read the options, drill into a picker), so it gets a longer auto-hide
    // window than a normal tap to avoid the HUD vanishing mid-selection.
    private static let settingsControlsAutoHideDelay: TimeInterval = controlsAutoHideDelay * 2
    private static let controlsAutoHideRetryDelay: TimeInterval = 0.25

    func startSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sync()
            }
        }
    }

    func sync() {
        let previousState = state
        let engineState = engine.state
        let now = Date()

        if engine.playerViewGeneration != lastPlayerViewGeneration {
            lastPlayerViewGeneration = engine.playerViewGeneration
            engineView = engine.makePlayerView()
        }

        if let pendingPlaybackState,
           let pendingPlaybackStateExpiration,
           now < pendingPlaybackStateExpiration,
           engineState != pendingPlaybackState {
            // Keep the play/pause icon responsive immediately after a tap
            // instead of snapping back while the engine catches up.
        } else {
            pendingPlaybackState = nil
            pendingPlaybackStateExpiration = nil
            state = engineState
        }

        // System transport, AirPlay and SharePlay can pause the engine without
        // going through the on-screen toggle. Reveal the HUD for those too.
        if state == .paused, previousState != .paused {
            touchControls()
        }

        if !isScrubbing {
            currentTime = engine.currentTime
        }
        duration = engine.duration
        seekableRange = engine.seekableTimeRange
        isBuffering = engine.isBuffering
        playbackError = engine.error
        videoEnhancementStatus = engine.videoEnhancementStatus

        let didStartPlayback = !hasStartedPlayback && (state == .playing || currentTime > 0)
        if didStartPlayback {
            hasStartedPlayback = true
        }

        updateLiveTimeline(now: now)
        updatePlaybackProgressTracking(now: now)
        updateBufferingPresentation(now: now)
        recoverStalledPlaybackIfNeeded(now: now)
        updateControlsAutoHide(didStartPlayback: didStartPlayback)
        syncTrackLists()
        applyAutomaticTrackSelectionIfNeeded()
        updateAutoSkipState()
        updateUpNextPosterNotification()
        playbackSnapshotHandler?(state, currentTime, duration)
    }

    /// Notifies the coordinator when the reached credits marker changes so it
    /// can raise or dismiss the bottom-right Up Next poster. Debounced by marker
    /// id so it only fires on genuine transitions, and skipped while scrubbing so
    /// a preview drag doesn't flap the poster.
    private func updateUpNextPosterNotification() {
        guard !isScrubbing else { return }

        let markerID = reachedCreditsMarker?.id
        guard markerID != lastNotifiedCreditsMarkerID else { return }

        lastNotifiedCreditsMarkerID = markerID
        upNextPosterHandler?(reachedCreditsMarker)
    }

    func togglePlayPause() {
        if isSpeedBoostActive {
            endSpeedBoost()
        }

        let targetState: PlaybackState = state == .playing ? .paused : .playing
        pendingPlaybackState = targetState
        pendingPlaybackStateExpiration = Date().addingTimeInterval(Self.pendingPlaybackStateGracePeriod)

        withAnimation(Self.playPauseAnimation) {
            state = targetState
        }

        switch targetState {
        case .paused:
            engine.pause()
        case .playing:
            engine.play()
        default:
            break
        }
        touchControls()
    }

    @discardableResult
    func beginSpeedBoost() -> Bool {
        guard liveTVContext == nil,
              state == .playing,
              playbackError == nil,
              !isSpeedBoostActive else {
            return false
        }

        engine.setPlaybackRate(2)
        withAnimation(.easeInOut(duration: 0.15)) {
            isSpeedBoostActive = true
        }
        return true
    }

    func endSpeedBoost() {
        guard isSpeedBoostActive else { return }

        // Back to the viewer's chosen speed, not blindly to 1×.
        engine.setPlaybackRate(playbackRate)
        withAnimation(.easeInOut(duration: 0.15)) {
            isSpeedBoostActive = false
        }
    }

    /// Sets the session's playback speed. Platform-neutral; today only the
    /// tvOS settings panel exposes it. A live session has no rate to change
    /// and a transient 2× boost wins until it is released — the boost's own
    /// `endSpeedBoost()` then restores whatever was chosen here.
    func setPlaybackRate(_ rate: Float) {
        guard liveTVContext == nil else { return }
        guard playbackRate != rate else { return }

        playbackRate = rate
        guard !isSpeedBoostActive else { return }
        engine.setPlaybackRate(rate)
    }

    func togglePictureInPicture() {
        if engine.isPictureInPictureActive {
            engine.stopPictureInPicture()
        } else {
            engine.startPictureInPicture()
        }
        noteControlsInteraction()
    }

    func toggleAspectFill() {
        aspectFillEnabled.toggle()
        engine.setVideoFillEnabled(aspectFillEnabled)
        // Remember the choice for the current orientation only; the other
        // orientation keeps whatever it was last left at.
        if let isLandscapeVideoOrientation {
            userPreferences?.setPlayerAspectFill(aspectFillEnabled, isLandscape: isLandscapeVideoOrientation)
        }
        noteControlsInteraction()
    }

    /// Records the current player orientation (portrait vs landscape) and
    /// applies that orientation's saved zoom-to-fill choice. Portrait and
    /// landscape keep independent settings, so rotating swaps the framing to
    /// whatever that orientation was last left at. Driven by the player's
    /// layout size, so it also covers iPad multitasking window shape changes.
    func updateVideoOrientation(isLandscape: Bool) {
        guard isLandscapeVideoOrientation != isLandscape else { return }
        isLandscapeVideoOrientation = isLandscape
        applyPersistedAspectFill()
    }

    /// Re-applies the persisted zoom-to-fill choice for the current orientation
    /// to both the button state and the engine. No-op until both the
    /// preferences reference and an orientation are known, so it is safe to call
    /// from `onAppear` and from the first layout pass in either order.
    func applyPersistedAspectFill() {
        guard let userPreferences, let isLandscapeVideoOrientation else { return }
        let enabled = userPreferences.playerAspectFill(isLandscape: isLandscapeVideoOrientation)
        aspectFillEnabled = enabled
        engine.setVideoFillEnabled(enabled)
    }

    func seek(by offset: TimeInterval, revealControls: Bool = false) {
        // Transient jump: the target is an approximate offset from the current
        // position, so let the engine take the fast keyframe-tolerant path.
        seek(to: displayPosition + offset, revealControls: revealControls, precise: false)
    }

    func handleSeekJump(by offset: TimeInterval) {
        showSeekFeedback(for: offset)
        seek(by: offset)
    }

    func handleDoubleTapSeek(by offset: TimeInterval) {
        handleSeekJump(by: offset)
    }

    func skipActiveMarker() {
        guard let marker = activeSkipMarker else { return }
        cancelAutoSkipCountdown(reason: "skip-activated")
        // Skipped once, by Dusk or by the viewer: this marker's auto-skip is
        // spent for the rest of the session.
        noteAutoSkipSpent(for: marker)

        let targetTime = (TimeInterval(marker.endTimeOffset) / 1000.0) + Self.markerSkipPadding
        autoSkipIntroLogger.notice(
            "Seeking past marker id=\(marker.id) type=\(marker.type, privacy: .public) from=\(self.displayPosition, format: .fixed(precision: 3)) to=\(targetTime, format: .fixed(precision: 3)) episode=\(self.currentEpisodeRatingKey ?? "unavailable", privacy: .public) mode=\(self.autoSkipIntroMode.rawValue, privacy: .public)"
        )
        seek(to: targetTime, revealControls: true)
    }

    /// Handles a tap on the Skip Intro button. Credits no longer route through
    /// here — they are handled by the bottom-right Up Next poster instead of a
    /// skip button.
    func handleSkipMarker(_ marker: PlexMarker) {
        cancelAutoSkipCountdown(reason: "skip-marker-action")
        skipActiveMarker()
    }

    func beginScrub() {
        finishIntroObservation(reason: "scrubbing", resolve: true, discardSegment: true)
        cancelAutoSkipCountdown(reason: "scrubbing")
        isScrubbing = true
        scrubPosition = currentTime
        cancelScheduledHide()
    }

    func updateScrub(to position: TimeInterval) {
        scrubPosition = clampedSeekPosition(position)
    }

    func endScrub() {
        commitScrub(shouldPlay: false)
    }

    func commitScrub(shouldPlay: Bool) {
        let targetPosition = scrubPosition
        // Final position the user deliberately chose — seek frame-accurately.
        seek(to: targetPosition, revealControls: false, precise: true)
        isScrubbing = false

        if shouldPlay {
            pendingPlaybackState = .playing
            pendingPlaybackStateExpiration = Date().addingTimeInterval(Self.pendingPlaybackStateGracePeriod)
            withAnimation(Self.playPauseAnimation) {
                state = .playing
            }
            engine.play()
        }

        touchControls()
    }

    func toggleControls() {
        let shouldShowControls = !showControls
        if shouldShowControls {
            resetControlsInteractionHold()
        }

        withAnimation(Self.controlsVisibilityAnimation) {
            showControls = shouldShowControls
        }

        if shouldShowControls {
            scheduleHide()
        } else {
            resetControlsInteractionHold()
            cancelScheduledHide()
        }
    }

    func touchControls() {
        #if os(tvOS)
        // Skip Intro can run without revealing the tvOS HUD.
        if suppressControlsReveal {
            scheduleHide()
            return
        }
        #endif

        let shouldRevealControls = !showControls
        if shouldRevealControls {
            resetControlsInteractionHold()
            withAnimation(Self.controlsVisibilityAnimation) {
                showControls = true
            }
        }
        scheduleHide()
    }

    func scheduleHide() {
        scheduleControlsAutoHide(resetDeadline: true)
    }

    func noteControlsInteraction() {
        guard showControls else { return }
        scheduleHide()
    }

    /// Refreshes the auto-hide deadline with the longer settings window when the
    /// user engages the playback settings menu. The menu takes a beat to open,
    /// read, and navigate, so the normal tap timeout is too short and the HUD
    /// would otherwise hide while the menu is still open. Mirrors
    /// `noteControlsInteraction()` and never reveals the HUD on its own, so a
    /// spurious menu lifecycle callback can't strand the controls on screen.
    func noteSettingsMenuInteraction() {
        guard showControls else { return }
        scheduleControlsAutoHide(resetDeadline: true, delay: Self.settingsControlsAutoHideDelay)
    }

    func beginControlsInteractionHold() {
        guard showControls else { return }
        controlsInteractionHoldCount += 1
        isControlsInteractionHeld = true
        scheduleControlsAutoHide(resetDeadline: false)
    }

    func endControlsInteractionHold() {
        controlsInteractionHoldCount = max(0, controlsInteractionHoldCount - 1)
        guard controlsInteractionHoldCount == 0 else { return }

        isControlsInteractionHeld = false
        scheduleHide()
    }

    func endAllControlsInteractionHolds() {
        resetControlsInteractionHold()
        scheduleHide()
    }

    /// `precise` defaults to frame-accurate for deliberate targets (marker
    /// skips, tvOS preview commits); `seek(by:)` opts transient double-tap and
    /// remote skip jumps into the engine's fast keyframe-tolerant path.
    func seek(to position: TimeInterval, revealControls: Bool, precise: Bool = true) {
        let clampedPosition = clampedSeekPosition(position)
        if introFrameSamplingMarkerID != nil {
            finishIntroObservation(reason: "seek", resolve: true, discardSegment: true)
        }
        // Any deliberate seek starts a separate recording, including a return
        // to a marker whose sampler was detached when playback left it.
        introOpeningSessionState.observations.removeAll()
        engine.seek(to: clampedPosition, precise: precise)

        if revealControls {
            touchControls()
        } else if showControls {
            scheduleHide()
        }
    }

    func clampedSeekPosition(_ position: TimeInterval) -> TimeInterval {
        if let seekableRange {
            return min(max(position, seekableRange.lowerBound), seekableRange.upperBound)
        }
        if duration > 0 {
            return min(max(position, 0), duration)
        }
        return max(position, 0)
    }

    /// Jumps back to the live edge and resumes if the session was paused —
    /// pausing is the usual way to fall behind, so "Go Live" that leaves the
    /// picture frozen would only be half the action.
    func goLive() {
        guard let seekableRange else { return }
        seek(to: max(seekableRange.lowerBound, seekableRange.upperBound - 1), revealControls: true)
        if state == .paused {
            togglePlayPause()
        }
    }

    // MARK: - Auto-Skip

    func updateAutoSkipState() {
        guard hasConfiguredAutomaticTrackSelection else {
            logAutoSkipDecision(reason: "configuration-not-ready", marker: nil)
            cancelAutoSkipCountdown(reason: "configuration-not-ready")
            return
        }
        if let preferences = userPreferences, autoSkipIntroMode != preferences.autoSkipIntroMode {
            cancelAutoSkipCountdown(reason: "saved-mode-changed")
            autoSkipIntroMode = preferences.autoSkipIntroMode
        }
        guard let marker = activeSkipMarker else {
            logAutoSkipDecision(reason: "no-active-marker", marker: nil)
            cancelAutoSkipCountdown(reason: "left-marker")
            return
        }
        guard !isScrubbing else {
            finishIntroObservation(reason: "scrubbing", resolve: true, discardSegment: true)
            cancelAutoSkipCountdown(reason: "scrubbing")
            return
        }
        guard marker.isIntro, shouldAutoSkipIntroMarkers,
              !introOpeningSessionState.hasSkippedIntro,
              !spentAutoSkipMarkerIDs.contains(marker.id) else {
            logAutoSkipDecision(reason: autoSkipIntroMode == .off ? "mode-off" : "marker-ineligible-or-spent", marker: marker)
            cancelAutoSkipCountdown(reason: "marker-ineligible-or-spent")
            return
        }
        if shouldClassifyIntroFingerprint {
            guard isIntroFingerprintCacheCurrent else {
                logAutoSkipDecision(reason: "fingerprint-cache-reset", marker: marker)
                cancelAutoSkipCountdown(reason: "fingerprint-cache-reset")
                return
            }
            logAutoSkipDecision(
                reason: engine.isReadyForIntroFrameSampling ? "intro-playback-ready" : "intro-waiting-for-playback",
                marker: marker
            )
            updateIntroRecognition(for: marker)
            return
        }
        if autoSkipCountdownMarkerID != marker.id {
            logAutoSkipDecision(reason: "countdown-arming", marker: marker)
            startAutoSkipCountdown(for: marker)
        }
    }

    private func logAutoSkipDecision(reason: String, marker: PlexMarker?) {
        let markerIdentity = marker.map {
            "\($0.id):\($0.type):\($0.startTimeOffset)-\($0.endTimeOffset)"
        } ?? "none"
        let seasonIdentity = introFingerprintSeasonKey.map {
            "\($0.serverID):\($0.seasonRatingKey)"
        } ?? "unavailable"
        let spent = marker.map { spentAutoSkipMarkerIDs.contains($0.id) } ?? false
        let resolved = marker.map { resolvedIntroFingerprintMarkerIDs.contains($0.id) } ?? false
        let snapshot = [
            reason,
            autoSkipIntroMode.rawValue,
            String(describing: currentMediaType),
            currentEpisodeRatingKey ?? "unavailable",
            seasonIdentity,
            markerIdentity,
            String(describing: state),
            String(isBuffering),
            String(isScrubbing),
            String(spent),
            String(resolved),
        ].joined(separator: "|")
        guard snapshot != lastAutoSkipDiagnosticSnapshot else { return }
        lastAutoSkipDiagnosticSnapshot = snapshot

        autoSkipIntroLogger.notice(
            "Decision model=\(ObjectIdentifier(self).debugDescription, privacy: .public) reason=\(reason, privacy: .public) mode=\(self.autoSkipIntroMode.rawValue, privacy: .public) type=\(String(describing: self.currentMediaType), privacy: .public) episode=\(self.currentEpisodeRatingKey ?? "unavailable", privacy: .public) fingerprintScope=\(seasonIdentity, privacy: .public) marker=\(markerIdentity, privacy: .public) state=\(String(describing: self.state), privacy: .public) buffering=\(self.isBuffering) scrubbing=\(self.isScrubbing) spent=\(spent) resolved=\(resolved) position=\(self.displayPosition, format: .fixed(precision: 3))"
        )
    }

    private func updateBufferingPresentation(now: Date) {
        // A paused session never presents buffering. `isBuffering` survives a
        // pause on AVPlayer (pausing out of `waitingToPlayAtSpecifiedRate`
        // leaves the flag set), and the controls hide the play/pause button
        // while this presentation is up — so without this the user could pause
        // a stalling stream and be left with a spinner and no way to resume.
        // The delay restarts on resume if the stream is still refilling.
        guard isBuffering,
              state != .paused,
              playbackError == nil,
              !isPlaybackMakingProgress(now: now) else {
            bufferingStartedAt = nil
            bufferingPresentationHandler?(false)
            return
        }

        let startedAt = bufferingStartedAt ?? now
        bufferingStartedAt = startedAt

        guard now.timeIntervalSince(startedAt) >= Self.bufferingIndicatorDelay else {
            bufferingPresentationHandler?(false)
            return
        }

        bufferingPresentationHandler?(true)
    }

    private func updateControlsAutoHide(didStartPlayback: Bool) {
        guard showControls else {
            cancelScheduledHide()
            return
        }

        guard shouldKeepControlsAutoHidePending else {
            cancelScheduledHide()
            return
        }

        scheduleControlsAutoHide(resetDeadline: didStartPlayback)
    }

    private func isPlaybackMakingProgress(now: Date) -> Bool {
        hasStartedPlayback &&
            state == .playing &&
            now.timeIntervalSince(lastProgressAt) < Self.bufferingIndicatorDelay
    }

    private var canAutoHideControls: Bool {
        #if DEBUG
        if ScreenshotMode.keepsPlayerHUD { return false }
        #endif
        return showControls &&
            controlsAutoHideIsArmed &&
            !isScrubbing &&
            !isControlsInteractionHeld &&
            playbackError == nil &&
            !showSubtitlePicker &&
            !showSubtitleSizePicker &&
            !showSubtitleSearch &&
            !showAudioPicker &&
            !showQualityPicker &&
            !showPlaybackInfo &&
            stateAllowsControlsAutoHide &&
            state != .stopped &&
            state != .error
    }

    private var shouldKeepControlsAutoHidePending: Bool {
        showControls &&
            controlsAutoHideIsArmed &&
            playbackError == nil &&
            stateAllowsControlsAutoHide &&
            state != .stopped &&
            state != .error
    }

    /// Pausing keeps the full HUD visible on both platforms. Resuming arms a
    /// fresh deadline through the normal interaction / sync path.
    private var stateAllowsControlsAutoHide: Bool {
        state == .playing
    }

    private func cancelScheduledHide() {
        controlsAutoHideTask?.cancel()
        controlsAutoHideTask = nil
        controlsAutoHideDeadline = nil
    }

    private func resetControlsInteractionHold() {
        controlsInteractionHoldCount = 0
        isControlsInteractionHeld = false
    }

    private var controlsAutoHideIsArmed: Bool {
        hasStartedPlayback || state == .playing || currentTime > 0
    }

    private func scheduleControlsAutoHide(resetDeadline: Bool, delay: TimeInterval = PlayerViewModel.controlsAutoHideDelay) {
        guard shouldKeepControlsAutoHidePending else {
            cancelScheduledHide()
            return
        }

        if resetDeadline || controlsAutoHideDeadline == nil {
            controlsAutoHideDeadline = Date().addingTimeInterval(delay)
        }

        guard controlsAutoHideTask == nil else { return }

        controlsAutoHideTask = Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                guard let deadline = self.controlsAutoHideDeadline else {
                    self.controlsAutoHideTask = nil
                    return
                }

                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(Self.milliseconds(remaining)))
                    } catch {
                        return
                    }
                    continue
                }

                if self.canAutoHideControls {
                    self.controlsAutoHideTask = nil
                    self.controlsAutoHideDeadline = nil
                    withAnimation(Self.controlsVisibilityAnimation) {
                        self.showControls = false
                    }
                    return
                }

                guard self.shouldKeepControlsAutoHidePending else {
                    self.controlsAutoHideTask = nil
                    self.controlsAutoHideDeadline = nil
                    return
                }

                self.controlsAutoHideDeadline = Date().addingTimeInterval(Self.controlsAutoHideRetryDelay)
            }
        }
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(1, Int((interval * 1000).rounded(.up)))
    }

    private func updatePlaybackProgressTracking(now: Date) {
        guard state == .playing || hasStartedPlayback else {
            lastProgressAt = now
            lastProgressPosition = currentTime
            stalledPlaybackStartedAt = nil
            stallRecoveryAttempts = 0
            lastStallRecoveryAt = nil
            return
        }

        if abs(currentTime - lastProgressPosition) > Self.stallProgressTolerance {
            lastProgressAt = now
            lastProgressPosition = currentTime
            stalledPlaybackStartedAt = nil
            stallRecoveryAttempts = 0
            return
        }

        if isBuffering, stalledPlaybackStartedAt == nil {
            stalledPlaybackStartedAt = now
        } else if !isBuffering {
            stalledPlaybackStartedAt = nil
        }
    }

    private func recoverStalledPlaybackIfNeeded(now: Date) {
        guard hasStartedPlayback,
              isBuffering,
              playbackError == nil,
              stallRecoveryAttempts < Self.maxStallRecoveryAttempts else {
            return
        }

        let stalledAt = stalledPlaybackStartedAt ?? lastProgressAt
        guard now.timeIntervalSince(stalledAt) >= Self.stallRecoveryDelay else { return }

        if let lastStallRecoveryAt,
           now.timeIntervalSince(lastStallRecoveryAt) < Self.stallRecoveryCooldown {
            return
        }

        stallRecoveryAttempts += 1
        lastStallRecoveryAt = now
        stalledPlaybackStartedAt = now
        engine.recoverFromStall()
    }

    /// The unconditional mode retains its normal five-second courtesy delay.
    /// Repeated openings use the independent streaming recognition state machine.
    private func startAutoSkipCountdown(for marker: PlexMarker) {
        cancelAutoSkipCountdown(reason: "new-unconditional-countdown")
        autoSkipCountdownMarkerID = marker.id
        autoSkipCountdownProgress = 0
        autoSkipCountdownTask = Task { @MainActor [weak self] in
            var elapsed: TimeInterval = 0
            var previous = Date()
            while !Task.isCancelled {
                guard let self, self.autoSkipCountdownMarkerID == marker.id,
                      self.hasConfiguredAutomaticTrackSelection,
                      self.shouldAutoSkipIntroMarkers, !self.shouldClassifyIntroFingerprint,
                      self.userPreferences?.autoSkipIntroMode == self.autoSkipIntroMode,
                      self.activeSkipMarker?.id == marker.id, !self.isScrubbing,
                      !self.introOpeningSessionState.hasSkippedIntro,
                      !self.spentAutoSkipMarkerIDs.contains(marker.id) else { return }
                let now = Date()
                if self.state != .paused { elapsed += min(Self.maximumAutoSkipCountdownTick, now.timeIntervalSince(previous)) }
                previous = now
                self.autoSkipCountdownProgress = min(1, elapsed / Self.autoSkipCountdownDuration)
                if elapsed >= Self.autoSkipCountdownDuration {
                    self.cancelAutoSkipCountdown(reason: "unconditional-countdown-complete")
                    self.performAutomaticIntroSkip(for: marker)
                    return
                }
                do { try await Task.sleep(for: Self.autoSkipCountdownPollingInterval) }
                catch { return }
            }
        }
    }

    private var shouldAutoSkipIntroMarkers: Bool {
        switch autoSkipIntroMode {
        case .off:
            return false
        case .always:
            return true
        case .alwaysExceptFirstEpisode:
            // Keep the legacy behavior for known non-episode markers. Episodes
            // and items without metadata need identity to classify safely.
            guard let currentMediaType else { return false }
            return currentMediaType != .episode || introFingerprintSeasonKey != nil
        }
    }

    var shouldClassifyIntroFingerprint: Bool {
        autoSkipIntroMode == .alwaysExceptFirstEpisode
            && currentMediaType == .episode
            && currentEpisodeRatingKey != nil
            && introFingerprintSeasonKey != nil
    }

    /// Claim the session's automatic skip before invoking a callback, which may
    /// seek asynchronously or rebuild the player. Manual button taps bypass
    /// this guard so a viewer can still choose to skip after rewinding.
    func performAutomaticIntroSkip(for marker: PlexMarker) {
        guard marker.isIntro, activeSkipMarker?.id == marker.id,
              !shouldClassifyIntroFingerprint || isIntroFingerprintCacheCurrent,
              !introOpeningSessionState.hasSkippedIntro,
              !spentAutoSkipMarkerIDs.contains(marker.id) else { return }
        noteAutoSkipSpent(for: marker)
        if let handler = autoSkipHandler { handler(marker) }
        else { skipActiveMarker() }
    }

    /// Burns this marker's one-shot auto-skip for the session and tells the
    /// coordinator, which keeps the record across player rebuilds.
    private func noteAutoSkipSpent(for marker: PlexMarker) {
        if marker.isIntro { introOpeningSessionState.hasSkippedIntro = true }
        guard spentAutoSkipMarkerIDs.insert(marker.id).inserted else { return }
        autoSkipIntroLogger.notice(
            "Marker marked spent marker=\(marker.id) episode=\(self.currentEpisodeRatingKey ?? "unavailable", privacy: .public)"
        )
        autoSkipSpentHandler?(marker.id)
    }

    func noteIntroFingerprintResolved(for marker: PlexMarker) {
        guard resolvedIntroFingerprintMarkerIDs.insert(marker.id).inserted else { return }
        autoSkipIntroLogger.notice(
            "Fingerprint classification resolved marker=\(marker.id) episode=\(self.currentEpisodeRatingKey ?? "unavailable", privacy: .public) resolvedMarkers=\(self.resolvedIntroFingerprintMarkerIDs.sorted().description, privacy: .public)"
        )
        introFingerprintResolvedHandler?(marker.id)
    }

    func cancelAutoSkipCountdown(reason: String = "cancelled") {
        autoSkipCountdownTask?.cancel()
        autoSkipCountdownTask = nil
        finishIntroObservation(reason: reason, resolve: true)
        autoSkipCountdownMarkerID = nil
        autoSkipCountdownProgress = nil
    }

    private func showSeekFeedback(for offset: TimeInterval) {
        let direction: PlayerSeekFeedbackPresentation.Direction = offset < 0 ? .backward : .forward
        let seconds = max(1, Int(abs(offset).rounded()))
        let nextTrigger = (seekFeedback?.trigger ?? 0) + 1

        if let currentFeedback = seekFeedback, currentFeedback.direction == direction {
            withAnimation(.easeOut(duration: 0.12)) {
                seekFeedback = PlayerSeekFeedbackPresentation(
                    direction: direction,
                    seconds: currentFeedback.seconds + seconds,
                    trigger: nextTrigger
                )
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                seekFeedback = PlayerSeekFeedbackPresentation(
                    direction: direction,
                    seconds: seconds,
                    trigger: nextTrigger
                )
            }
        }

        seekFeedbackTask?.cancel()
        seekFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.seekFeedbackDisplayDuration)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                self.seekFeedback = nil
            }
        }
    }
}
