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
        upNextPresentation.autoplayProgress = nil
        self.upNextPresentation = upNextPresentation
    }

    func presentUpNext(for episode: PlexEpisode) {
        presentUpNext(for: episode, source: .playbackEnded)
    }

    func presentUpNext(for episode: PlexEpisode, source: UpNextPresentation.Source) {
        cancelUpNextCountdown()

        let autoplayBlockedByPassoutProtection = shouldPauseContinuousPlayAutoplay()
        let shouldAutoplay = preferences.continuousPlayEnabled && !autoplayBlockedByPassoutProtection

        upNextPresentation = UpNextPresentation(
            episode: episode,
            source: source,
            shouldAutoplay: shouldAutoplay,
            countdownDuration: preferences.continuousPlayCountdown.rawValue,
            secondsRemaining: shouldAutoplay ? preferences.continuousPlayCountdown.rawValue : nil,
            autoplayProgress: shouldAutoplay ? 0 : nil,
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
            let duration = Double(presentation.countdownDuration)

            guard duration > 0 else {
                await self.startUpNextPlayback(trigger: .autoplay)
                return
            }

            let startedAt = Date()

            while true {
                if Task.isCancelled { return }

                guard var current = self.upNextPresentation,
                      current.shouldAutoplay else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                let clampedElapsed = min(max(elapsed, 0), duration)
                current.secondsRemaining = max(0, Int(ceil(duration - clampedElapsed)))
                current.autoplayProgress = min(max(clampedElapsed / duration, 0), 1)
                self.upNextPresentation = current

                if clampedElapsed >= duration {
                    break
                }

                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }

            if Task.isCancelled { return }

            if var current = self.upNextPresentation, current.shouldAutoplay {
                current.secondsRemaining = 0
                current.autoplayProgress = 1
                self.upNextPresentation = current
            }

            await self.startUpNextPlayback(trigger: .autoplay)
        }
    }

    func cancelUpNextCountdown() {
        upNextCountdownTask?.cancel()
        upNextCountdownTask = nil
    }

    func skipCreditsToUpNextIfPossible() async -> Bool {
        guard upNextPresentation == nil else { return true }

        guard let activeItemDetails,
              activeItemDetails.type == .episode,
              let nextEpisode = try? await plexService.getNextEpisode(after: activeItemDetails) else {
            return false
        }

        guard upNextPresentation == nil else { return true }

        finalizeCurrentPlaybackSession(markCompleted: true)
        presentUpNext(for: nextEpisode, source: .creditsSkipped)
        return true
    }

    private func startUpNextPlayback(trigger: UpNextStartTrigger) async {
        guard var presentation = upNextPresentation,
              !presentation.isStarting else { return }

        switch trigger {
        case .autoplay:
            upNextCountdownTask = nil
        case .manual:
            cancelUpNextCountdown()
        }
        presentation.isStarting = true
        presentation.errorMessage = nil
        presentation.autoplayProgress = 1
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
        failedPresentation.autoplayProgress = nil
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
