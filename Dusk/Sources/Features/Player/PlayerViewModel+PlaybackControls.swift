import Foundation
import SwiftUI

extension PlayerViewModel {
    /// The HUD's fade curve. Used for both directions so revealing and hiding
    /// the controls are mirror images. `PlayerView` reads it too, so it cannot
    /// be private.
    static let controlsVisibilityAnimation: Animation = .easeInOut(duration: 0.125)
    private static let playPauseAnimation: Animation = .snappy(duration: 0.1)
    private static let pendingPlaybackStateGracePeriod: TimeInterval = 0.35
    private static let seekFeedbackDisplayDuration: Duration = .milliseconds(325)
    /// Credits ending this close to the item's end have nothing left to show.
    private static let creditsSkipEndTolerance: TimeInterval = 2
    private static let markerSkipPadding: TimeInterval = 0.5
    /// How long the Skip Intro chip counts down before it skips or hides.
    /// Tests shorten it; playback always uses five seconds.
    static var autoSkipCountdownDuration: TimeInterval = 5.0
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
        creditsMarkerWithoutUpNextID = nil
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

    /// Rates offered by the speed control (advanced playback controls).
    static let playbackSpeedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    static func playbackSpeedTitle(_ rate: Float) -> String {
        rate == 1 ? "Normal" : String(format: "%g×", Double(rate))
    }

    /// Sets the session's playback speed, from the iOS speed menu or the tvOS
    /// panel's Speed tab (both only with advanced playback controls on). A
    /// live session has no rate to change and a transient 2× boost wins until
    /// it is released — the boost's own `endSpeedBoost()` then restores
    /// whatever was chosen here.
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
        cancelAutoSkipCountdown()
        // Skipped once, by Dusk or by the viewer: this marker's auto-skip is
        // spent for the rest of the session.
        noteAutoSkipSpent(for: marker)

        let targetTime = (TimeInterval(marker.endTimeOffset) / 1000.0) + Self.markerSkipPadding
        if marker.isCredits, duration > 0, targetTime >= duration - Self.creditsSkipEndTolerance,
           let skipToEndHandler {
            skipToEndHandler()
            return
        }
        seek(to: targetTime, revealControls: true)
    }

    /// Handles a tap on a skip chip (Skip Intro, or Skip Credits where the Up
    /// Next poster does not cover them; see `activeSkipMarker`).
    func handleSkipMarker(_ marker: PlexMarker) {
        cancelAutoSkipCountdown()
        skipActiveMarker()
    }

    func beginScrub() {
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
        engine.seek(to: targetPosition, precise: true)
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
            cancelAutoSkipCountdown()
            return
        }

        // The in-player copy can lag a settings change made while the chip is
        // up. Refresh it so the countdown's finish reads the mode the viewer
        // last chose.
        if let userPreferences {
            autoSkipIntroMode = userPreferences.autoSkipIntroMode
        }
        clearCountdownDismissalIfPlayheadLeftMarker()

        let marker = activeSkipMarker

        guard let marker, !isScrubbing else {
            if autoSkipCountdownMarkerID != nil {
                cancelAutoSkipCountdown()
            }
            return
        }

        // One auto-skip per marker per session. Without this the countdown
        // re-arms the moment the position lands back inside the marker — which
        // happens on its own while a post-skip seek is still buffering, and
        // again whenever the viewer deliberately rewinds into the intro.
        // A spent marker still shows the chip for a manual skip; the countdown
        // stays off so expiry cannot hide that chip or jump forward again.
        if spentAutoSkipMarkerIDs.contains(marker.id) {
            if autoSkipCountdownMarkerID != nil {
                cancelAutoSkipCountdown()
            }
            return
        }

        // Already counting down for this marker. Auto-skip off keeps the same
        // countdown running: expiry hides the chip instead of cancelling it.
        if autoSkipCountdownMarkerID == marker.id { return }

        startAutoSkipCountdown(for: marker)
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

        // A pause is not a stall, and its length must not count towards one.
        if state == .paused {
            lastProgressAt = now
            lastProgressPosition = currentTime
            stalledPlaybackStartedAt = nil
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
        // Recovery reloads the item (and starts it playing), so it must never
        // touch a paused session: a healthy HDR remux lost its picture this way
        // (#59).
        guard hasStartedPlayback,
              isBuffering,
              state != .paused,
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
        ErrorReporter.report(.playbackStallRecovery, count: stallRecoveryAttempts)
        engine.recoverFromStall()
    }

    private func startAutoSkipCountdown(for marker: PlexMarker) {
        cancelAutoSkipCountdown()
        autoSkipCountdownMarkerID = marker.id
        autoSkipCountdownProgress = 0
        autoSkipCountdownClock = UpNextCountdownClock(duration: Self.autoSkipCountdownDuration)

        autoSkipCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let duration = Self.autoSkipCountdownDuration
            var clock = UpNextCountdownClock(duration: duration)

            while true {
                if Task.isCancelled { return }

                let now = Date()
                if self.state == .paused {
                    clock.freeze(at: now)
                } else {
                    clock.resume(at: now)
                }

                // The tvOS chip's sweep runs on its own from the clock, so the
                // player re-renders for a pause, never for a tick.
                if self.autoSkipCountdownClock != clock {
                    self.autoSkipCountdownClock = clock
                }
                #if !os(tvOS)
                if clock.runningSince != nil {
                    self.autoSkipCountdownProgress = clock.progress(at: now)
                }
                #endif

                if clock.elapsed(at: now) >= duration { break }

                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch { return }
            }

            if Task.isCancelled { return }

            self.finishAutoSkipCountdown(for: marker)
        }
    }

    /// Countdown reached zero while `marker` is still the active chip. Auto-skip
    /// on (Auto-Skip Intros / Auto-Skip Credits by marker type) skips it.
    /// Auto-skip off (including "always except episode 1" on the first episode)
    /// only hides the chip.
    private func finishAutoSkipCountdown(for marker: PlexMarker) {
        guard autoSkipCountdownMarkerID == marker.id else { return }

        guard let currentMarker = activeSkipMarker,
              currentMarker.id == marker.id else {
            cancelAutoSkipCountdown()
            return
        }

        guard hasConfiguredAutomaticTrackSelection,
              !isScrubbing,
              !spentAutoSkipMarkerIDs.contains(currentMarker.id) else {
            cancelAutoSkipCountdown()
            return
        }

        autoSkipCountdownMarkerID = nil
        autoSkipCountdownProgress = nil
        autoSkipCountdownClock = nil

        let shouldSkip = currentMarker.isCredits
            ? userPreferences?.autoSkipCredits == true
            : shouldAutoSkipIntroMarkers
        guard shouldSkip else {
            countdownDismissedMarkerID = currentMarker.id
            return
        }

        if let handler = autoSkipHandler {
            handler(currentMarker)
        } else {
            skipActiveMarker()
        }
    }

    /// A dismissed chip stays gone only while playback is still inside that
    /// marker. Leaving it (or seeking back in later) offers Skip Intro again.
    private func clearCountdownDismissalIfPlayheadLeftMarker() {
        guard let dismissedID = countdownDismissedMarkerID else { return }
        let positionMs = Int(displayPosition * 1000)
        let stillInside = markers.contains { marker in
            marker.id == dismissedID && marker.contains(positionMs: positionMs)
        }
        if !stillInside {
            countdownDismissedMarkerID = nil
        }
    }

    private var shouldAutoSkipIntroMarkers: Bool {
        let mode = userPreferences?.autoSkipIntroMode ?? autoSkipIntroMode
        return mode.shouldAutoSkipIntro(isFirstEpisodeInSeason: isFirstEpisodeInSeason)
    }

    /// Burns this marker's one-shot auto-skip for the session and tells the
    /// coordinator, which keeps the record across player rebuilds.
    private func noteAutoSkipSpent(for marker: PlexMarker) {
        guard spentAutoSkipMarkerIDs.insert(marker.id).inserted else { return }
        autoSkipSpentHandler?(marker.id)
    }

    /// Back on the tvOS remote while the chip counts down (#76): Plex can place
    /// a marker early, so the viewer stops the countdown without leaving the
    /// player. The chip stays up for a manual skip; the marker counts as spent,
    /// so the countdown never re-arms for it this session. Returns false when no
    /// countdown is running, leaving Back to its usual job.
    @discardableResult
    func haltAutoSkipCountdown() -> Bool {
        guard let markerID = autoSkipCountdownMarkerID,
              let marker = activeSkipMarker,
              marker.id == markerID else { return false }
        cancelAutoSkipCountdown()
        noteAutoSkipSpent(for: marker)
        return true
    }

    func cancelAutoSkipCountdown() {
        autoSkipCountdownTask?.cancel()
        autoSkipCountdownTask = nil
        autoSkipCountdownMarkerID = nil
        autoSkipCountdownProgress = nil
        autoSkipCountdownClock = nil
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
