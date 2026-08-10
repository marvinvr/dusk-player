import Foundation

extension PlaybackCoordinator {
    enum UpNextStartTrigger {
        case autoplay
        case manual
    }

    func playUpNextNow() {
        Task { @MainActor in
            await startUpNextPlayback(trigger: .manual)
        }
    }

    func playUpNextPosterNow() {
        Task { @MainActor in
            await startUpNextPosterPlayback(trigger: .manual)
        }
    }

    func cancelUpNextAutoplay() {
        guard var upNextPresentation else { return }
        cancelUpNextCountdown()
        upNextPresentation.shouldAutoplay = false
        upNextPresentation.countdownStartedAt = nil
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
            countdownStartedAt: shouldAutoplay ? Date() : nil,
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
            let startedAt = presentation.countdownStartedAt ?? Date()

            guard duration > 0 else {
                await self.startUpNextPlayback(trigger: .autoplay)
                return
            }

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

    // MARK: - Up Next Poster

    /// Resolves the next episode and shows the bottom-right "next episode"
    /// poster once the credits marker is reached. Called from the player when
    /// the reached credits marker changes; safe to call repeatedly for the same
    /// marker (it no-ops once a poster for that marker is up).
    func presentUpNextPosterIfPossible(
        creditsMarkerID: Int,
        isEstimated: Bool,
        presentationID expectedPresentationID: UUID,
        ratingKey expectedRatingKey: String?
    ) async {
        guard isActiveSession(presentationID: expectedPresentationID, ratingKey: expectedRatingKey) else { return }
        if let existing = upNextPoster, existing.creditsMarkerID == creditsMarkerID { return }
        // The full-screen Up Next screen takes precedence over the poster.
        guard upNextPresentation == nil else { return }

        guard let activeItemDetails,
              activeItemDetails.type == .episode else { return }

        let resolvedNextEpisode: PlexEpisode?
        if activePlaybackUsesLocalDownload {
            resolvedNextEpisode = cachedNextEpisode(after: activeItemDetails)
        } else {
            resolvedNextEpisode = await nextEpisode(after: activeItemDetails)
        }

        guard let nextEpisode = resolvedNextEpisode else { return }
        guard isActiveSession(presentationID: expectedPresentationID, ratingKey: expectedRatingKey) else { return }
        guard upNextPresentation == nil else { return }
        // A poster for a newer credits marker was raised while we resolved.
        if let existing = upNextPoster, existing.creditsMarkerID != creditsMarkerID { return }

        let mode = upNextPosterMode(estimated: isEstimated)
        var poster = UpNextPosterPresentation(
            episode: nextEpisode,
            mode: mode,
            creditsMarkerID: creditsMarkerID
        )
        if case let .timedAutoplay(countdown) = mode {
            poster.secondsRemaining = countdown
            poster.countdownProgress = 0
        }
        upNextPoster = poster

        if poster.isTimed {
            startUpNextPosterCountdown()
        }
    }

    /// Hides the poster and cancels any pending auto-advance. Used when the user
    /// seeks back out of the credits or drags the poster down: the current
    /// episode keeps playing to its end, and the full-screen Up Next screen only
    /// appears once it actually finishes (via `handlePlaybackEnded`).
    func dismissUpNextPoster() {
        cancelUpNextPosterCountdown()
        upNextPoster = nil
    }

    /// Plays the poster's next episode immediately — a poster tap or a fired
    /// countdown. Finalizes the current session first because the poster shows
    /// while the current episode is still playing, unlike the full-screen Up
    /// Next screen whose callers finalize before presenting.
    func startUpNextPosterPlayback(trigger: UpNextStartTrigger) async {
        guard var poster = upNextPoster, !poster.isStarting else { return }

        cancelUpNextPosterCountdown()
        poster.isStarting = true
        poster.secondsRemaining = 0
        poster.countdownProgress = 1
        upNextPoster = poster

        finalizeCurrentPlaybackSession(markCompleted: true)

        let attemptID = UUID()
        currentPlaybackAttemptID = attemptID
        let didStart = await startPlaybackSession(
            ratingKey: poster.episode.ratingKey,
            startPositionOverride: nil,
            resumeOffsetMilliseconds: poster.episode.viewOffset,
            selectedMediaID: nil,
            attemptID: attemptID
        )

        // Superseded by a newer attempt or a dismissal while loading.
        guard currentPlaybackAttemptID == attemptID else { return }

        if didStart {
            switch trigger {
            case .autoplay:
                continuousPlayEpisodeRunCount += 1
            case .manual:
                resetContinuousPlayEpisodeRunCountForCurrentItem()
            }
            // `startPlaybackSession` clears `upNextPoster` when the new engine
            // commits.
            return
        }

        // The next episode failed to start — surface the full-screen Up Next
        // screen with an error instead of leaving a dead poster behind.
        let episode = poster.episode
        upNextPoster = nil
        cancelUpNextCountdown()
        upNextPresentation = UpNextPresentation(
            episode: episode,
            source: .playbackEnded,
            shouldAutoplay: false,
            countdownDuration: preferences.continuousPlayCountdown.rawValue,
            countdownStartedAt: nil,
            secondsRemaining: nil,
            autoplayProgress: nil,
            autoplayBlockedByPassoutProtection: false,
            passoutProtectionEpisodeLimit: nil,
            errorMessage: loadError ?? "Could not start the next episode."
        )
        loadError = nil
    }

    func startUpNextPosterCountdown() {
        guard let poster = upNextPoster,
              case let .timedAutoplay(countdown) = poster.mode,
              !poster.isStarting else { return }

        cancelUpNextPosterCountdown()

        let duration = Double(countdown)
        guard duration > 0 else {
            upNextPosterCountdownTask = Task { @MainActor [weak self] in
                await self?.startUpNextPosterPlayback(trigger: .autoplay)
            }
            return
        }

        upNextPosterCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var pausedAt: Date?
            var accumulatedPausedTime: TimeInterval = 0

            while true {
                if Task.isCancelled { return }

                guard var current = self.upNextPoster,
                      current.isTimed,
                      !current.isStarting else { return }

                let now = Date()
                // Freeze the countdown while the user pauses during credits.
                if self.latestActivePlaybackState == .paused {
                    pausedAt = pausedAt ?? now
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch { return }
                    continue
                }

                if let pausedAt {
                    accumulatedPausedTime += now.timeIntervalSince(pausedAt)
                }
                pausedAt = nil

                let elapsed = now.timeIntervalSince(startedAt) - accumulatedPausedTime
                let clampedElapsed = min(max(elapsed, 0), duration)
                current.secondsRemaining = max(0, Int(ceil(duration - clampedElapsed)))
                current.countdownProgress = min(max(clampedElapsed / duration, 0), 1)
                self.upNextPoster = current

                if clampedElapsed >= duration { break }

                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch { return }
            }

            if Task.isCancelled { return }
            await self.startUpNextPosterPlayback(trigger: .autoplay)
        }
    }

    func cancelUpNextPosterCountdown() {
        upNextPosterCountdownTask?.cancel()
        upNextPosterCountdownTask = nil
    }

    private func upNextPosterMode(estimated: Bool) -> UpNextPosterPresentation.Mode {
        // A guessed credits point (no real Plex marker) must never auto-skip or
        // auto-advance — only ever a manual poster the user can choose to tap.
        if estimated { return .manual }

        let autoplayBlockedByPassoutProtection = shouldPauseContinuousPlayAutoplay()
        guard preferences.continuousPlayEnabled,
              !autoplayBlockedByPassoutProtection else {
            return .manual
        }

        if preferences.autoSkipCredits {
            return .timedAutoplay(countdown: preferences.continuousPlayCountdown.rawValue)
        }
        return .autoAdvanceAtEnd
    }

    func nextEpisode(after episode: PlexMediaDetails) async -> PlexEpisode? {
        if let nextEpisode = try? await plexService.getNextEpisode(after: episode) {
            return nextEpisode
        }

        return cachedNextEpisode(after: episode)
    }

    private func cachedNextEpisode(after episode: PlexMediaDetails) -> PlexEpisode? {
        downloadManager?.cachedNextDownloadedEpisode(after: episode)
    }

    private func isActiveSession(presentationID expectedPresentationID: UUID, ratingKey expectedRatingKey: String?) -> Bool {
        playerPresentationID == expectedPresentationID && ratingKey == expectedRatingKey
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

        // The overlay stays up as the loading state for the next episode (its
        // Play button shows the spinner) until the new engine commits. The old,
        // already-finalized engine keeps showing behind it.
        let attemptID = UUID()
        currentPlaybackAttemptID = attemptID
        let nextRatingKey = presentation.episode.ratingKey
        let didStart = await startPlaybackSession(
            ratingKey: nextRatingKey,
            startPositionOverride: nil,
            resumeOffsetMilliseconds: presentation.episode.viewOffset,
            selectedMediaID: nil,
            attemptID: attemptID
        )

        // Superseded by a newer attempt or a dismissal while loading.
        guard currentPlaybackAttemptID == attemptID else { return }

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
        failedPresentation.countdownStartedAt = nil
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
