import Foundation
import SwiftUI

extension PlayerViewModel {
    private static let controlsVisibilityAnimation: Animation = .easeInOut(duration: 0.125)
    private static let playPauseAnimation: Animation = .snappy(duration: 0.1)
    private static let pendingPlaybackStateGracePeriod: TimeInterval = 0.35
    private static let seekFeedbackDisplayDuration: Duration = .milliseconds(325)
    private static let markerSkipPadding: TimeInterval = 0.5
    private static let autoSkipCountdownDuration: TimeInterval = 5.0
    private static let bufferingIndicatorDelay: TimeInterval = 2.0
    private static let stallRecoveryDelay: TimeInterval = 12.0
    private static let stallRecoveryCooldown: TimeInterval = 8.0
    private static let stallProgressTolerance: TimeInterval = 0.75
    private static let maxStallRecoveryAttempts = 2

    func startSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sync()
            }
        }
    }

    func sync() {
        let previousState = state
        let previousIsBuffering = isBuffering
        let engineState = engine.state
        let now = Date()

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

        if !isScrubbing {
            currentTime = engine.currentTime
        }
        duration = engine.duration
        isBuffering = engine.isBuffering
        playbackError = engine.error

        let didStartPlayback = !hasStartedPlayback && (state == .playing || currentTime > 0)
        if didStartPlayback {
            hasStartedPlayback = true
        }

        updatePlaybackProgressTracking(now: now)
        updateBufferingPresentation(now: now)
        recoverStalledPlaybackIfNeeded(now: now)
        scheduleControlsHideIfPlaybackBecameReady(
            previousState: previousState,
            previousIsBuffering: previousIsBuffering,
            didStartPlayback: didStartPlayback,
            now: now
        )
        syncTrackLists()
        applyAutomaticTrackSelectionIfNeeded()
        updateAutoSkipState()
        playbackSnapshotHandler?(state, currentTime, duration)
    }

    func togglePlayPause() {
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

    func seek(by offset: TimeInterval, revealControls: Bool = false) {
        seek(to: displayPosition + offset, revealControls: revealControls)
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

        let targetTime = (TimeInterval(marker.endTimeOffset) / 1000.0) + Self.markerSkipPadding
        seek(to: targetTime, revealControls: true)
    }

    func handleSkipMarker(
        _ marker: PlexMarker,
        skipCreditsToUpNext: @escaping @MainActor () async -> Bool
    ) {
        cancelAutoSkipCountdown()

        guard marker.isCredits else {
            skipActiveMarker()
            return
        }

        markerSkipTask?.cancel()
        markerSkipTask = Task { @MainActor [weak self] in
            let didPresentUpNext = await skipCreditsToUpNext()
            guard !Task.isCancelled else { return }

            if !didPresentUpNext {
                self?.skipActiveMarker()
            }

            self?.markerSkipTask = nil
        }
    }

    func beginScrub() {
        isScrubbing = true
        scrubPosition = currentTime
        hideTimer?.invalidate()
    }

    func updateScrub(to position: TimeInterval) {
        scrubPosition = max(0, min(position, duration))
    }

    func endScrub() {
        engine.seek(to: scrubPosition)
        isScrubbing = false
        touchControls()
    }

    func toggleControls() {
        let shouldShowControls = !showControls
        withAnimation(Self.controlsVisibilityAnimation) {
            showControls = shouldShowControls
        }

        if shouldShowControls {
            scheduleHide()
        } else {
            hideTimer?.invalidate()
        }
    }

    func touchControls() {
        if !showControls {
            withAnimation(Self.controlsVisibilityAnimation) {
                showControls = true
            }
        }
        scheduleHide()
    }

    func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .playing,
                   !self.isScrubbing,
                   !self.shouldHoldControlsForBuffering(now: Date()) {
                    withAnimation(Self.controlsVisibilityAnimation) {
                        self.showControls = false
                    }
                }
            }
        }
    }

    func seek(to position: TimeInterval, revealControls: Bool) {
        let clampedPosition: TimeInterval
        if duration > 0 {
            clampedPosition = min(max(position, 0), duration)
        } else {
            clampedPosition = max(position, 0)
        }

        engine.seek(to: clampedPosition)

        if revealControls {
            touchControls()
        } else if showControls {
            scheduleHide()
        }
    }

    // MARK: - Auto-Skip

    private func updateAutoSkipState() {
        let marker = activeSkipMarker

        guard let marker, !isScrubbing else {
            if autoSkipCountdownMarkerID != nil {
                cancelAutoSkipCountdown()
            }
            return
        }

        let shouldAutoSkip = (marker.isIntro && autoSkipIntro) || (marker.isCredits && autoSkipCredits)

        guard shouldAutoSkip else {
            if autoSkipCountdownMarkerID != nil {
                cancelAutoSkipCountdown()
            }
            return
        }

        // Already counting down for this marker
        if autoSkipCountdownMarkerID == marker.id { return }

        startAutoSkipCountdown(for: marker)
    }

    private func updateBufferingPresentation(now: Date) {
        guard isBuffering,
              playbackError == nil,
              !isPlaybackMakingProgress(now: now) else {
            bufferingStartedAt = nil
            if showBufferingIndicator {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showBufferingIndicator = false
                }
            }
            return
        }

        let startedAt = bufferingStartedAt ?? now
        bufferingStartedAt = startedAt

        guard now.timeIntervalSince(startedAt) >= Self.bufferingIndicatorDelay,
              !showBufferingIndicator else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            showBufferingIndicator = true
        }
    }

    private func scheduleControlsHideIfPlaybackBecameReady(
        previousState: PlaybackState,
        previousIsBuffering: Bool,
        didStartPlayback: Bool,
        now: Date
    ) {
        guard showControls,
              state == .playing,
              !isScrubbing,
              playbackError == nil,
              !shouldHoldControlsForBuffering(now: now) else {
            return
        }

        if didStartPlayback || previousState != .playing || previousIsBuffering {
            scheduleHide()
        }
    }

    private func shouldHoldControlsForBuffering(now: Date) -> Bool {
        isBuffering && !isPlaybackMakingProgress(now: now)
    }

    private func isPlaybackMakingProgress(now: Date) -> Bool {
        hasStartedPlayback &&
            state == .playing &&
            now.timeIntervalSince(lastProgressAt) < Self.bufferingIndicatorDelay
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

    private func startAutoSkipCountdown(for marker: PlexMarker) {
        cancelAutoSkipCountdown()
        autoSkipCountdownMarkerID = marker.id
        autoSkipCountdownProgress = 0

        autoSkipCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let duration = Self.autoSkipCountdownDuration
            let startedAt = Date()
            var pausedAt: Date?
            var accumulatedPausedTime: TimeInterval = 0

            while true {
                if Task.isCancelled { return }

                let now = Date()
                if self.state == .paused {
                    pausedAt = pausedAt ?? now
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch { return }
                    continue
                }

                if let pausedAt {
                    accumulatedPausedTime += now.timeIntervalSince(pausedAt)
                }

                pausedAt = nil

                let elapsed = now.timeIntervalSince(startedAt) - accumulatedPausedTime
                let progress = min(max(elapsed / duration, 0), 1)
                self.autoSkipCountdownProgress = progress

                if progress >= 1 { break }

                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch { return }
            }

            if Task.isCancelled { return }

            guard let currentMarker = self.activeSkipMarker,
                  currentMarker.id == self.autoSkipCountdownMarkerID else { return }

            self.autoSkipCountdownMarkerID = nil
            self.autoSkipCountdownProgress = nil

            if let handler = self.autoSkipHandler {
                handler(currentMarker)
            } else {
                self.skipActiveMarker()
            }
        }
    }

    func cancelAutoSkipCountdown() {
        autoSkipCountdownTask?.cancel()
        autoSkipCountdownTask = nil
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
