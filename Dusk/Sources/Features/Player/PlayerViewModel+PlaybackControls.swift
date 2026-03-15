import Foundation
import SwiftUI

extension PlayerViewModel {
    private static let controlsVisibilityAnimation: Animation = .easeInOut(duration: 0.125)
    private static let seekFeedbackDisplayDuration: Duration = .milliseconds(325)
    private static let markerSkipPadding: TimeInterval = 0.5
    private static let autoSkipCountdownDuration: TimeInterval = 5.0

    func startSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sync()
            }
        }
    }

    func sync() {
        state = engine.state
        if !isScrubbing {
            currentTime = engine.currentTime
        }
        duration = engine.duration
        isBuffering = engine.isBuffering
        if !hasStartedPlayback, (state == .playing || currentTime > 0) {
            hasStartedPlayback = true
        }
        playbackError = engine.error
        syncTrackLists()
        applyAutomaticTrackSelectionIfNeeded()
        updateAutoSkipState()
    }

    func togglePlayPause() {
        if state == .playing {
            engine.pause()
        } else {
            engine.play()
        }
        touchControls()
    }

    func seek(by offset: TimeInterval, revealControls: Bool = false) {
        seek(to: displayPosition + offset, revealControls: revealControls)
    }

    func handleDoubleTapSeek(by offset: TimeInterval) {
        showSeekFeedback(for: offset)
        seek(by: offset)
    }

    func skipActiveMarker() {
        guard let marker = activeSkipMarker else { return }
        cancelAutoSkipCountdown()

        let targetTime = (TimeInterval(marker.endTimeOffset) / 1000.0) + Self.markerSkipPadding
        seek(to: targetTime, revealControls: true)
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
                if self.state == .playing, !self.isScrubbing {
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
