import Foundation

extension PlaybackCoordinator {
    private enum UpNextStartTrigger {
        case autoplay
        case manual
    }

    func playUpNextNow() {
        Task { @MainActor in
            await startUpNextPlayback(trigger: .manual)
        }
    }

    func cancelUpNextAutoplay() {
        guard var upNextPresentation else { return }
        cancelUpNextCountdown()
        upNextPresentation.shouldAutoplay = false
        upNextPresentation.secondsRemaining = nil
        self.upNextPresentation = upNextPresentation
    }

    func presentUpNext(for episode: PlexEpisode) {
        cancelUpNextCountdown()

        let autoplayBlockedByPassoutProtection = shouldPauseContinuousPlayAutoplay()
        let shouldAutoplay = preferences.continuousPlayEnabled && !autoplayBlockedByPassoutProtection

        upNextPresentation = UpNextPresentation(
            episode: episode,
            shouldAutoplay: shouldAutoplay,
            countdownDuration: preferences.continuousPlayCountdown.rawValue,
            secondsRemaining: shouldAutoplay ? preferences.continuousPlayCountdown.rawValue : nil,
            autoplayBlockedByPassoutProtection: autoplayBlockedByPassoutProtection,
            passoutProtectionEpisodeLimit: preferences.continuousPlayPassoutProtectionEpisodeLimit
        )

        if shouldAutoplay {
            startUpNextCountdown()
        }
    }

    func startUpNextCountdown() {
        guard let presentation = upNextPresentation,
              presentation.shouldAutoplay else { return }

        cancelUpNextCountdown()

        upNextCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for remaining in stride(from: presentation.countdownDuration, through: 1, by: -1) {
                if Task.isCancelled { return }

                guard var current = self.upNextPresentation,
                      current.shouldAutoplay else { return }
                current.secondsRemaining = remaining
                self.upNextPresentation = current

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }

            if Task.isCancelled { return }
            await self.startUpNextPlayback(trigger: .autoplay)
        }
    }

    func cancelUpNextCountdown() {
        upNextCountdownTask?.cancel()
        upNextCountdownTask = nil
    }

    private func startUpNextPlayback(trigger: UpNextStartTrigger) async {
        guard var presentation = upNextPresentation,
              !presentation.isStarting else { return }

        cancelUpNextCountdown()
        presentation.isStarting = true
        presentation.errorMessage = nil
        upNextPresentation = presentation

        let nextRatingKey = presentation.episode.ratingKey
        let didStart = await startPlaybackSession(
            ratingKey: nextRatingKey,
            startPositionOverride: nil,
            presentPlayer: false
        )
        if didStart {
            switch trigger {
            case .autoplay:
                continuousPlayEpisodeRunCount += 1
            case .manual:
                resetContinuousPlayEpisodeRunCountForCurrentItem()
            }
            return
        }

        guard var failedPresentation = upNextPresentation else { return }
        failedPresentation.isStarting = false
        failedPresentation.shouldAutoplay = false
        failedPresentation.secondsRemaining = nil
        failedPresentation.errorMessage = loadError ?? "Could not start the next episode."
        upNextPresentation = failedPresentation
        loadError = nil
    }

    private func shouldPauseContinuousPlayAutoplay() -> Bool {
        guard preferences.continuousPlayEnabled,
              let episodeLimit = preferences.continuousPlayPassoutProtectionEpisodeLimit else {
            return false
        }

        return continuousPlayEpisodeRunCount >= episodeLimit
    }
}
