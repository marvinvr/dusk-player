import Foundation
import OSLog

private let upNextLogger = Logger(subsystem: "com.dusk-player.app", category: "UpNext")

/// What Up Next offers after the item now playing: the next playlist item in
/// a queue session, otherwise the next episode of the show.
struct UpNextCandidate: Sendable {
    let item: PlaybackQueueItem
    /// Position in `PlaybackCoordinator.playbackQueue`; nil for the show's
    /// next episode.
    let queueIndex: Int?
}

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

    func presentUpNext(for candidate: UpNextCandidate) {
        presentUpNext(for: candidate, source: .playbackEnded)
    }

    func presentUpNext(for candidate: UpNextCandidate, source: UpNextPresentation.Source) {
        cancelUpNextCountdown()

        let autoplayBlockedByPassoutProtection = shouldPauseContinuousPlayAutoplay()
        let shouldAutoplay = preferences.continuousPlayEnabled && !autoplayBlockedByPassoutProtection

        upNextPresentation = UpNextPresentation(
            item: candidate.item,
            queueIndex: candidate.queueIndex,
            queueTitle: queueTitle(for: candidate),
            source: source,
            shouldAutoplay: shouldAutoplay,
            countdownDuration: preferences.continuousPlayCountdown.rawValue,
            countdownStartedAt: shouldAutoplay ? Date() : nil,
            secondsRemaining: shouldAutoplay ? preferences.continuousPlayCountdown.rawValue : nil,
            autoplayProgress: shouldAutoplay ? 0 : nil,
            autoplayBlockedByPassoutProtection: autoplayBlockedByPassoutProtection,
            passoutProtectionEpisodeLimit: preferences.continuousPlayPassoutProtectionEpisodeLimit
        )

        #if DEBUG
        // The overlay times a running countdown from its start date; without one
        // it shows the frozen `secondsRemaining` the countdown task publishes.
        if ScreenshotMode.frozenUpNextSeconds != nil {
            upNextPresentation?.countdownStartedAt = nil
        }
        #endif

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

                let rawElapsed = Date().timeIntervalSince(startedAt)
                #if DEBUG
                let elapsed = ScreenshotMode.frozenUpNextSeconds
                    .map { min(rawElapsed, duration - Double($0)) } ?? rawElapsed
                #else
                let elapsed = rawElapsed
                #endif
                let clampedElapsed = min(max(elapsed, 0), duration)
                let secondsRemaining = max(0, Int(ceil(duration - clampedElapsed)))
                // The overlay's sweep runs on its own from `countdownStartedAt`,
                // so the player re-renders for a new second, not for a tick. A
                // frozen screenshot has no start date and draws from the fraction.
                if current.secondsRemaining != secondsRemaining || current.countdownStartedAt == nil {
                    current.secondsRemaining = secondsRemaining
                    current.autoplayProgress = min(max(clampedElapsed / duration, 0), 1)
                    self.upNextPresentation = current
                }

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
    ///
    /// - Returns: true when nothing follows this item (a film, a show's last
    ///   episode, the end of a queue), so no poster can ever appear for it.
    @discardableResult
    func presentUpNextPosterIfPossible(
        creditsMarkerID: Int,
        isEstimated: Bool,
        presentationID expectedPresentationID: UUID,
        ratingKey expectedRatingKey: String?
    ) async -> Bool {
        guard isActiveSession(presentationID: expectedPresentationID, ratingKey: expectedRatingKey) else { return false }
        if let existing = upNextPoster, existing.creditsMarkerID == creditsMarkerID { return false }
        // The full-screen Up Next screen takes precedence over the poster.
        guard upNextPresentation == nil else { return false }

        guard let activeItemDetails else { return false }

        let startedAt = ContinuousClock.now
        let resolved = await resolveUpNext(after: activeItemDetails, prefersDownloadCache: true)
        guard isActiveSession(presentationID: expectedPresentationID, ratingKey: expectedRatingKey) else { return false }
        guard let candidate = resolved else { return true }
        guard upNextPresentation == nil else { return false }
        // A poster for a newer credits marker was raised while we resolved.
        if let existing = upNextPoster, existing.creditsMarkerID != creditsMarkerID { return false }

        let mode = upNextPosterMode(creditsMarkerID: creditsMarkerID, estimated: isEstimated)
        var poster = UpNextPosterPresentation(
            item: candidate.item,
            queueIndex: candidate.queueIndex,
            queueTitle: queueTitle(for: candidate),
            mode: mode,
            creditsMarkerID: creditsMarkerID
        )
        if case let .timedAutoplay(countdown) = mode {
            poster.secondsRemaining = countdown
            poster.countdownClock = UpNextCountdownClock(duration: Double(countdown))
        }
        upNextPoster = poster
        upNextLogger.notice(
            "Up Next poster ready \(Self.milliseconds(since: startedAt), privacy: .public) ms after the credits marker (\(candidate.queueIndex == nil ? "next episode" : "queue", privacy: .public))"
        )

        if poster.isTimed {
            // The auto-advance is now armed for this episode's credits; a later
            // return to them raises a manual poster instead of a fresh
            // countdown.
            noteAutoSkipSpent(markerID: creditsMarkerID)
            startUpNextPosterCountdown()
        }
        return false
    }

    /// Hides the poster and cancels any pending auto-advance. Used when the user
    /// seeks back out of the credits or drags the poster down: the current
    /// episode keeps playing to its end, and the full-screen Up Next screen only
    /// appears once it actually finishes (via `handlePlaybackEnded`).
    ///
    /// `userInitiated` marks the dismissal as the viewer waving the auto-advance
    /// off. Reaching the credits again (after seeking back before them) may then
    /// still offer the poster, but only as a manual one — Dusk does not restart
    /// a countdown the viewer already cancelled.
    func dismissUpNextPoster(userInitiated: Bool = false) {
        if userInitiated, let creditsMarkerID = upNextPoster?.creditsMarkerID {
            noteAutoSkipSpent(markerID: creditsMarkerID)
        }
        cancelUpNextPosterCountdown()
        upNextPoster = nil
    }

    /// Plays the poster's next episode immediately — a poster tap or a fired
    /// countdown. Finalizes the current session first because the poster shows
    /// while the current episode is still playing, unlike the full-screen Up
    /// Next screen whose callers finalize before presenting.
    func startUpNextPosterPlayback(trigger: UpNextStartTrigger) async {
        guard var poster = upNextPoster, !poster.isStarting else { return }
        // The lookahead may have found the queued item gone since the poster
        // went up: start what the queue offers now, or end with the queue.
        if poster.queueIndex != nil {
            guard let current = revalidatedQueueCandidate(UpNextCandidate(item: poster.item, queueIndex: poster.queueIndex)) else {
                endPlaybackAtQueueEnd()
                return
            }
            poster.item = current.item
            poster.queueIndex = current.queueIndex
        }

        cancelUpNextPosterCountdown()
        poster.isStarting = true
        poster.secondsRemaining = 0
        poster.countdownClock?.finish()
        upNextPoster = poster

        finalizeCurrentPlaybackSession(markCompleted: true)

        let attemptID = UUID()
        currentPlaybackAttemptID = attemptID
        let previousQueuePosition = moveQueue(to: poster.queueIndex)
        let didStart = await runPlaybackAttempt(
            id: poster.item.id,
            startPositionOverride: nil,
            resumeOffsetMilliseconds: poster.queueIndex == nil ? poster.item.viewOffset : poster.item.queueResumeFallbackOffset,
            resumeOffsetDurationMilliseconds: poster.item.duration,
            selectedMediaID: nil,
            attemptID: attemptID
        )

        // Superseded by a newer attempt or a dismissal while loading.
        guard currentPlaybackAttemptID == attemptID else { return }
        if !didStart {
            moveQueue(to: previousQueuePosition)
        }

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

        // A queued item that turns out to be gone from its server is skipped:
        // offer the one after it instead of an error that a retry repeats.
        if poster.queueIndex != nil, await skipQueueItemIfGone(poster.item) {
            upNextPoster = nil
            loadError = nil
            return
        }

        // The next episode failed to start — surface the full-screen Up Next
        // screen with an error instead of leaving a dead poster behind.
        upNextPoster = nil
        cancelUpNextCountdown()
        upNextPresentation = UpNextPresentation(
            item: poster.item,
            queueIndex: poster.queueIndex,
            queueTitle: poster.queueTitle,
            source: .playbackEnded,
            shouldAutoplay: false,
            countdownDuration: preferences.continuousPlayCountdown.rawValue,
            countdownStartedAt: nil,
            secondsRemaining: nil,
            autoplayProgress: nil,
            autoplayBlockedByPassoutProtection: false,
            passoutProtectionEpisodeLimit: nil,
            errorMessage: loadError ?? Self.upNextStartFailureMessage(for: poster.item)
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
                self?.upNextPosterCountdownTask = nil
                await self?.startUpNextPosterPlayback(trigger: .autoplay)
            }
            return
        }

        upNextPosterCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var clock = UpNextCountdownClock(duration: duration)

            while true {
                if Task.isCancelled { return }

                guard var current = self.upNextPoster,
                      current.isTimed,
                      !current.isStarting else { return }

                let now = Date()
                // Freeze the countdown while the user pauses during credits.
                var isHeld = self.latestActivePlaybackState == .paused
                #if DEBUG
                if let frozenSeconds = ScreenshotMode.frozenUpNextSeconds,
                   clock.elapsed(at: now) >= duration - Double(frozenSeconds) {
                    isHeld = true
                }
                #endif
                if isHeld {
                    clock.freeze(at: now)
                } else {
                    clock.resume(at: now)
                }

                // This loop only watches the clock. The sweep runs on its own
                // from `countdownClock`, so the player re-renders for a new
                // second or a pause, never for a tick.
                let secondsRemaining = clock.secondsRemaining(at: now)
                if current.countdownClock != clock || current.secondsRemaining != secondsRemaining {
                    current.countdownClock = clock
                    current.secondsRemaining = secondsRemaining
                    self.upNextPoster = current
                }

                if clock.elapsed(at: now) >= duration { break }

                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch { return }
            }

            if Task.isCancelled { return }
            // This task now runs the start. Letting go of it first keeps
            // `cancelUpNextPosterCountdown` from cancelling the attempt itself,
            // which fails every timed advance with no error of its own.
            self.upNextPosterCountdownTask = nil
            await self.startUpNextPosterPlayback(trigger: .autoplay)
        }
    }

    func cancelUpNextPosterCountdown() {
        upNextPosterCountdownTask?.cancel()
        upNextPosterCountdownTask = nil
    }

    private func upNextPosterMode(creditsMarkerID: Int, estimated: Bool) -> UpNextPosterPresentation.Mode {
        // A guessed credits point (no real Plex marker) must never auto-skip or
        // auto-advance — only ever a manual poster the user can choose to tap.
        if estimated { return .manual }

        // The auto-advance for these credits already had its turn this episode
        // (it ran, or the viewer dismissed it). Re-entering the credits offers
        // the poster again, but the viewer taps it themselves.
        if spentAutoSkipMarkerIDs.contains(creditsMarkerID) { return .manual }

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

    // MARK: - Previous / Next Episode

    /// Whether the player's Previous / Next Episode controls may act. Off while
    /// a SharePlay group is (or is becoming) attached: a manual jump would
    /// leave the group behind on the old episode.
    var canStepEpisodes: Bool {
        !isSharePlayActive && !isSharePlayStarting
    }

    /// Resolves the playing item's neighbours once per item. Called at
    /// session commit; a Quality switch or delivery fallback of the same item
    /// keeps what was already resolved. A queue session reads them straight
    /// from the queue (no request) and prefetches the next item; otherwise
    /// only episodes have neighbours. Download sessions only see downloaded
    /// neighbours; an online lookup that fails falls back to them too, like
    /// `nextEpisode(after:)`.
    func refreshAdjacentEpisodesIfNeeded() {
        guard let details = activeItemDetails,
              activeLiveTVContext == nil,
              let itemID = activeItemID else {
            clearAdjacentEpisodes()
            return
        }
        guard adjacentEpisodes?.itemID != itemID
                || adjacentEpisodes?.queuePosition != playbackQueue?.position else { return }

        if playbackQueue != nil {
            adjacentEpisodesTask?.cancel()
            adjacentEpisodesTask = nil
            adjacentEpisodes = queueNeighbours(itemID: itemID)
            prefetchNextQueueItem()
            return
        }

        guard details.type == .episode else {
            clearAdjacentEpisodes()
            return
        }

        adjacentEpisodesTask?.cancel()
        adjacentEpisodes = PlaybackAdjacentEpisodes(itemID: itemID)
        let usesLocalDownload = activePlaybackUsesLocalDownload

        adjacentEpisodesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var resolved: PlexAdjacentEpisodes?
            var isOnlineEpisodeLookup = false
            if !usesLocalDownload {
                resolved = try? await self.plexService.getAdjacentEpisodes(around: details)
                isOnlineEpisodeLookup = resolved != nil
            }
            if resolved == nil {
                resolved = self.downloadManager?.cachedAdjacentDownloadedEpisodes(around: details)
            }

            guard !Task.isCancelled, self.adjacentEpisodes?.itemID == itemID else { return }
            self.adjacentEpisodes = PlaybackAdjacentEpisodes(
                itemID: itemID,
                isResolved: true,
                previous: resolved?.previous.map { .init(item: PlaybackQueueItem(episode: $0)) },
                next: resolved?.next.map { .init(item: PlaybackQueueItem(episode: $0)) },
                isOnlineEpisodeLookup: isOnlineEpisodeLookup
            )
        }
    }

    func clearAdjacentEpisodes() {
        adjacentEpisodesTask?.cancel()
        adjacentEpisodesTask = nil
        queueLookaheadTask?.cancel()
        queueLookaheadTask = nil
        adjacentEpisodes = nil
    }

    /// Previous / Next Episode from the player. The current episode is marked
    /// watched only when the viewer is past its credits (`isPastCredits`);
    /// past 90 % it is scrobbled by finalization anyway. Anything earlier just
    /// reports its progress. Goes through the normal play flow (loading cover
    /// on the target's artwork, resume offset, server fallback), which also
    /// restarts the Pause After count from this episode.
    func playAdjacentEpisode(_ direction: AdjacentEpisodeDirection, isPastCredits: Bool) {
        guard canStepEpisodes,
              let neighbour = adjacentEpisodes?.neighbour(direction) else { return }

        cancelUpNextPosterCountdown()
        finalizeCurrentPlaybackSession(markCompleted: isPastCredits)

        // A playlist session keeps its queue, moved onto the neighbour.
        var queue = playbackQueue
        if let index = neighbour.queueIndex {
            queue?.move(to: index)
        }
        let item = neighbour.item
        Task { @MainActor in
            if let queue, neighbour.queueIndex != nil {
                await playQueue(queue)
            } else {
                await play(
                    id: item.id,
                    resumeOffsetMilliseconds: item.viewOffset,
                    resumeOffsetDurationMilliseconds: item.duration,
                    placeholder: PlaybackPlaceholder(queueItem: item)
                )
            }
        }
    }

    // MARK: - Resolving Up Next

    /// The one place Up Next decides what follows `details`.
    ///
    /// - A queue session answers from the queue, synchronously: the next item
    ///   that can play (downloaded, or its server connected). Its end is the
    ///   end of playback — never the show's next episode.
    /// - Otherwise only an episode has a successor. The neighbours resolved at
    ///   session commit already hold it when that online lookup succeeded, so
    ///   the credits poster needs no request of its own. Without that answer
    ///   (still running, offline, failed) it is resolved as it always was:
    ///   from the download cache when `prefersDownloadCache` and the session
    ///   plays a download, else `nextEpisode(after:)`.
    func resolveUpNext(after details: PlexMediaDetails, prefersDownloadCache: Bool) async -> UpNextCandidate? {
        if let playbackQueue {
            return playbackQueue.next(isPlayable: isQueueItemPlayable).map {
                UpNextCandidate(item: $0.item, queueIndex: $0.index)
            }
        }

        guard details.type == .episode else { return nil }

        if prefersDownloadCache, activePlaybackUsesLocalDownload {
            return cachedNextEpisode(after: details).map {
                UpNextCandidate(item: PlaybackQueueItem(episode: $0), queueIndex: nil)
            }
        }

        // Only a positive answer is reused. "No next episode" goes through the
        // old lookup, which re-asks the server (an episode may have been added
        // since) and falls back to a downloaded next episode the server no
        // longer lists.
        if let adjacentEpisodes,
           adjacentEpisodes.itemID == activeItemID,
           adjacentEpisodes.isResolved,
           adjacentEpisodes.isOnlineEpisodeLookup,
           let next = adjacentEpisodes.next {
            return UpNextCandidate(item: next.item, queueIndex: nil)
        }

        return await nextEpisode(after: details).map {
            UpNextCandidate(item: PlaybackQueueItem(episode: $0), queueIndex: nil)
        }
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

    // MARK: - Playback Queue

    /// Whether a queued item can start now: its server is connected, or it is
    /// downloaded (which plays with no server at all).
    func isQueueItemPlayable(_ item: PlaybackQueueItem) -> Bool {
        if downloadManager?.isPlayableOffline(id: item.id) == true { return true }
        return plexService.pool.connection(for: item.serverID) != nil
    }

    /// Moves the queue onto the item an Up Next start is about to play, so the
    /// commit inside `runPlaybackAttempt` already sees the new position.
    /// Returns the position it replaced (to restore when the start fails);
    /// nil, and nothing happens, outside a queue session.
    @discardableResult
    func moveQueue(to index: Int?) -> Int? {
        guard let index, var queue = playbackQueue else { return nil }
        let previous = queue.position
        queue.move(to: index)
        playbackQueue = queue
        return previous
    }

    private func queueTitle(for candidate: UpNextCandidate) -> String? {
        candidate.queueIndex == nil ? nil : playbackQueue?.title
    }

    private func queueNeighbours(itemID: PlexItemID) -> PlaybackAdjacentEpisodes {
        let queue = playbackQueue
        return PlaybackAdjacentEpisodes(
            itemID: itemID,
            queuePosition: queue?.position,
            isResolved: true,
            previous: queue?.previous(isPlayable: isQueueItemPlayable).map {
                .init(item: $0.item, queueIndex: $0.index)
            },
            next: queue?.next(isPlayable: isQueueItemPlayable).map {
                .init(item: $0.item, queueIndex: $0.index)
            }
        )
    }

    /// Fetches the next queued item's metadata while the current one plays,
    /// the way the show's next episode is resolved at commit for episodes.
    /// Fresh watch state replaces the playlist's copy (it may have been
    /// watched elsewhere since the list was read). Items the server no longer
    /// has are marked unavailable one after another until one answers, so a
    /// run of removed entries never blocks play-through; a poster already
    /// offering one moves on with it (`noteQueueItemUnavailable`). Any other
    /// failure stops quietly. Downloaded items are not fetched — they play
    /// from disk.
    private func prefetchNextQueueItem() {
        queueLookaheadTask?.cancel()
        guard let itemID = activeItemID, let position = playbackQueue?.position else { return }

        queueLookaheadTask = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled,
                      self.isCurrentQueueState(itemID: itemID, position: position),
                      let next = self.playbackQueue?.next(isPlayable: self.isQueueItemPlayable),
                      self.downloadManager?.isPlayableOffline(id: next.item.id) != true else { return }

                do {
                    let details = try await self.queueItemLookup(next.item)
                    guard !Task.isCancelled, self.isCurrentQueueState(itemID: itemID, position: position) else { return }
                    self.playbackQueue?.replaceItem(at: next.index, with: PlaybackQueueItem(details: details))
                    self.adjacentEpisodes = self.queueNeighbours(itemID: itemID)
                    return
                } catch PlexServiceError.httpError(statusCode: 404) {
                    guard !Task.isCancelled, self.isCurrentQueueState(itemID: itemID, position: position) else { return }
                    self.noteQueueItemUnavailable(next.item.id)
                } catch {
                    // Offline or slow: Up Next still offers the item, and
                    // starting it reports a real failure if there is one.
                    return
                }
            }
        }
    }

    private func isCurrentQueueState(itemID: PlexItemID, position: Int) -> Bool {
        adjacentEpisodes?.itemID == itemID && playbackQueue?.position == position
    }

    /// Marks a queued item gone and moves everything that offers it on: the
    /// Previous / Next targets, and an Up Next poster or screen that has not
    /// started yet (to the item after it, or away when it was the last).
    func noteQueueItemUnavailable(_ id: PlexItemID) {
        guard playbackQueue != nil else { return }
        upNextLogger.notice("Queued item \(id.storageKey, privacy: .public) is gone from its server; skipping it")
        playbackQueue?.markUnavailable(id)
        if let itemID = adjacentEpisodes?.itemID {
            adjacentEpisodes = queueNeighbours(itemID: itemID)
        }

        if var poster = upNextPoster, poster.queueIndex != nil, poster.item.id == id, !poster.isStarting {
            if let next = revalidatedQueueCandidate(UpNextCandidate(item: poster.item, queueIndex: poster.queueIndex)) {
                poster.item = next.item
                poster.queueIndex = next.queueIndex
                upNextPoster = poster
            } else {
                dismissUpNextPoster()
            }
        }
        if var presentation = upNextPresentation, presentation.queueIndex != nil,
           presentation.item.id == id, !presentation.isStarting,
           let next = revalidatedQueueCandidate(UpNextCandidate(item: presentation.item, queueIndex: presentation.queueIndex)) {
            presentation.item = next.item
            presentation.queueIndex = next.queueIndex
            upNextPresentation = presentation
        }
    }

    /// The queued candidate if it can still play, else what the queue offers
    /// after the current position now; nil at the end of the queue.
    func revalidatedQueueCandidate(_ candidate: UpNextCandidate) -> UpNextCandidate? {
        guard let queue = playbackQueue, candidate.queueIndex != nil else { return candidate }
        if let index = candidate.queueIndex,
           queue.items.indices.contains(index),
           queue.items[index].id == candidate.item.id,
           !queue.unavailableIDs.contains(candidate.item.id),
           isQueueItemPlayable(candidate.item) {
            return candidate
        }
        return queue.next(isPlayable: isQueueItemPlayable).map { UpNextCandidate(item: $0.item, queueIndex: $0.index) }
    }

    /// After a queued item failed to start: if its server says it is gone,
    /// mark it, and offer the next item (or end playback at the queue's end).
    /// Returns false when it is not gone, so the caller shows the error.
    private func skipQueueItemIfGone(_ item: PlaybackQueueItem) async -> Bool {
        do {
            _ = try await queueItemLookup(item)
            return false
        } catch PlexServiceError.httpError(statusCode: 404) {
            playbackQueue?.markUnavailable(item.id)
            upNextPresentation = nil
            if let next = playbackQueue?.next(isPlayable: isQueueItemPlayable) {
                presentUpNext(for: UpNextCandidate(item: next.item, queueIndex: next.index))
            } else {
                endPlaybackAtQueueEnd()
            }
            return true
        } catch {
            return false
        }
    }

    /// The queue has nothing left to play: the same ending as an item with
    /// no Up Next (`handlePlaybackEnded`).
    private func endPlaybackAtQueueEnd() {
        upNextPoster = nil
        upNextPresentation = nil
        cancelUpNextCountdown()
        cancelUpNextPosterCountdown()
        finalizeCurrentPlaybackSession(markCompleted: true)
        sharePlayController.leave()
        showPlayer = false
    }

    private static func upNextStartFailureMessage(for item: PlaybackQueueItem) -> String {
        item.isEpisode ? "Could not start the next episode." : "Could not start the next item."
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func isActiveSession(presentationID expectedPresentationID: UUID, ratingKey expectedRatingKey: String?) -> Bool {
        playerPresentationID == expectedPresentationID && ratingKey == expectedRatingKey
    }

    private func startUpNextPlayback(trigger: UpNextStartTrigger) async {
        guard var presentation = upNextPresentation,
              !presentation.isStarting else { return }
        if presentation.queueIndex != nil {
            guard let current = revalidatedQueueCandidate(UpNextCandidate(item: presentation.item, queueIndex: presentation.queueIndex)) else {
                endPlaybackAtQueueEnd()
                return
            }
            presentation.item = current.item
            presentation.queueIndex = current.queueIndex
        }

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
        let previousQueuePosition = moveQueue(to: presentation.queueIndex)
        let didStart = await runPlaybackAttempt(
            id: presentation.item.id,
            startPositionOverride: nil,
            resumeOffsetMilliseconds: presentation.queueIndex == nil ? presentation.item.viewOffset : presentation.item.queueResumeFallbackOffset,
            resumeOffsetDurationMilliseconds: presentation.item.duration,
            selectedMediaID: nil,
            attemptID: attemptID
        )

        // Superseded by a newer attempt or a dismissal while loading.
        guard currentPlaybackAttemptID == attemptID else { return }
        if !didStart {
            moveQueue(to: previousQueuePosition)
        }

        if didStart {
            switch trigger {
            case .autoplay:
                continuousPlayEpisodeRunCount += 1
            case .manual:
                resetContinuousPlayEpisodeRunCountForCurrentItem()
            }
            return
        }

        if presentation.queueIndex != nil, await skipQueueItemIfGone(presentation.item) {
            loadError = nil
            return
        }

        guard var failedPresentation = upNextPresentation else { return }
        failedPresentation.isStarting = false
        failedPresentation.shouldAutoplay = false
        failedPresentation.countdownStartedAt = nil
        failedPresentation.secondsRemaining = nil
        failedPresentation.autoplayProgress = nil
        failedPresentation.errorMessage = loadError ?? Self.upNextStartFailureMessage(for: failedPresentation.item)
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
