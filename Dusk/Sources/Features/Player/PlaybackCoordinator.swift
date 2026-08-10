import Foundation
import SwiftUI

enum PlayerLoadingState: Equatable {
    case hidden
    case preparing
    case starting
    case buffering
    case recovering

    var isVisible: Bool {
        self != .hidden
    }
}

/// Orchestrates the "play an item" flow: fetch metadata → resolve engine →
/// construct URL → present player → report timeline → scrobble.
///
/// Injected into the environment so any view can trigger playback via
/// `coordinator.play(ratingKey:resumeOffsetMilliseconds:)`. The player is
/// presented as a full-screen cover in MainTabView.
@MainActor @Observable
final class PlaybackCoordinator {
    var showPlayer = false
    var loadError: String?
    /// What we know about the item being loaded (title/poster), shown by the
    /// player cover's loading state until the engine takes over. Nil once a
    /// session commits or the cover is torn down.
    var loadingPlaceholder: PlaybackPlaceholder?
    var engine: (any PlaybackEngine)?
    var debugInfo: PlaybackDebugInfo?
    var playbackSource: PlaybackSource?
    var playerPresentationID = UUID()
    /// The session whose delayed mid-play buffering presentation is active.
    /// The id prevents a departing session from clearing its successor's state.
    private var bufferingPresentationID: UUID?
    var upNextPresentation: UpNextPresentation?
    /// The small bottom-right "next episode" poster shown over the play bar once
    /// the credits marker is reached (replaces the old Skip Credits button). Nil
    /// when not in credits, when there is no next episode, or while the
    /// full-screen `upNextPresentation` is showing instead.
    var upNextPoster: UpNextPosterPresentation?
    var isSwitchingQuality = false
    var qualitySwitchError: String?
    /// True while an online direct-play attempt still has its one-shot Plex
    /// server-stream fallback available. Used to keep a transient engine error
    /// hidden until that recovery attempt succeeds or definitively fails.
    var isAutomaticDirectPlayFallbackAvailable = false
    /// True only after direct play has failed and Plex is preparing the
    /// replacement server stream. Drives the continuous loading presentation.
    var isAutomaticDirectPlayFallbackActive = false
    /// True while a Picture in Picture window is showing. The full-screen player
    /// cover is dropped while this is set, so the engine must outlive the cover's
    /// dismissal (see `onPlayerDismissed`).
    var isPictureInPictureActive = false
    /// Completion handed up by AVKit's restore delegate; fired once the
    /// re-presented player UI reports it is on screen.
    @ObservationIgnored var pendingPictureInPictureRestoreCompletion: ((Bool) -> Void)?

    let plexService: PlexService
    let preferences: UserPreferences
    let downloadManager: DownloadManager?
    let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    @ObservationIgnored let nowPlayingController = PlaybackNowPlayingController()
    var ratingKey: String?
    var activePlaybackServerID: String?
    var activePlaybackUsesLocalDownload = false
    var activeItemDetails: PlexMediaDetails?
    var activeLiveTVContext: PlexLivePlaybackContext?
    var hasScrobbled = false
    var didFinalizeCurrentSession = false
    var isHandlingPlaybackEnded = false
    var lastReportedTimeMs = 0
    var lastReportedDurationMs = 0
    var continuousPlayEpisodeRunCount = 0
    var activePlaybackSessionIdentifier: String?
    var activeTranscodeSessionID: String?
    /// Counts 10-second timeline ticks so the transcode keep-alive ping fires
    /// roughly every 60 seconds while a server transcode session is active.
    @ObservationIgnored var transcodePingTickCounter = 0

    /// Identifies the in-flight playback attempt. Set when an attempt begins
    /// (fresh Play or Up Next) and checked after every `await` so a dismissal or
    /// a newer attempt supersedes a slow load instead of committing over it.
    @ObservationIgnored var currentPlaybackAttemptID: UUID?

    /// Latest play/pause state reported by the active session, fed from the
    /// player's snapshot handler. The Up Next poster countdown reads it so it
    /// freezes while the user pauses during the credits instead of autoplaying.
    @ObservationIgnored var latestActivePlaybackState: PlaybackState = .idle

    /// Whether the system idle timer (screen saver / auto-lock) should be
    /// suppressed. Owned here rather than in `PlayerSessionView` because that
    /// view is rebuilt (fresh `.id`) on every episode transition: two idle-timer
    /// modifiers would overlap during the swap and the departing one would clear
    /// the flag the arriving one just set, letting the screen saver appear on the
    /// next episode. Driven off the continuously-polled playback state so a
    /// transient wrong value self-corrects on the following tick.
    var isIdleTimerSuppressed = false

    @ObservationIgnored nonisolated(unsafe) var timelineTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var upNextCountdownTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var upNextPosterCountdownTask: Task<Void, Never>?
    /// One-shot per attempt: observes the engine after an online direct-play
    /// start and swaps the session to the server-stream ladder rung when the
    /// engine fails. Cancelled on finalize/clear/engine swap.
    @ObservationIgnored nonisolated(unsafe) var directPlayFallbackWatchTask: Task<Void, Never>?
    /// Keeps the tuned Live TV channel's schedule current for the length of the
    /// session. Cancelled with the session.
    @ObservationIgnored nonisolated(unsafe) var liveTVScheduleRefreshTask: Task<Void, Never>?

    init(
        plexService: PlexService,
        preferences: UserPreferences = UserPreferences(),
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        self.plexService = plexService
        self.preferences = preferences
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
    }

    deinit {
        timelineTimer?.invalidate()
        directPlayFallbackWatchTask?.cancel()
        upNextPosterCountdownTask?.cancel()
        liveTVScheduleRefreshTask?.cancel()
    }

    /// Single source of truth for the full-screen player loading presentation.
    /// PlayerView renders exactly one persistent spinner from this state.
    var playerLoadingState: PlayerLoadingState {
        guard showPlayer else { return .hidden }

        guard let engine else {
            return loadError == nil ? .preparing : .hidden
        }

        let hasAutomaticFallback = isAutomaticDirectPlayFallbackAvailable ||
            isAutomaticDirectPlayFallbackActive
        if case .directPlay? = debugInfo?.decision,
           hasAutomaticFallback,
           engine.state == .error || engine.error != nil {
            return .recovering
        }

        if engine.state == .error || engine.error != nil {
            return .hidden
        }

        if engine.state == .idle || engine.state == .loading {
            return .starting
        }

        if bufferingPresentationID == playerPresentationID {
            return .buffering
        }

        return .hidden
    }

    func setBufferingPresentationVisible(
        _ isVisible: Bool,
        for presentationID: UUID
    ) {
        guard presentationID == playerPresentationID else { return }

        let newValue = isVisible ? presentationID : nil
        if bufferingPresentationID != newValue {
            bufferingPresentationID = newValue
        }
    }

    // MARK: - Play an Item

    /// Full "play an item" flow. The player cover is presented immediately on a
    /// loading placeholder, then metadata is fetched → engine picked → URL built
    /// → session committed under the already-visible cover. `placeholder` is what
    /// the caller already knows (title/poster) so the loading screen isn't blank.
    func play(
        ratingKey: String,
        resumeOffsetMilliseconds: Int?,
        placeholder: PlaybackPlaceholder? = nil
    ) async {
        await beginPlayback(
            ratingKey: ratingKey,
            startPositionOverride: nil,
            resumeOffsetMilliseconds: resumeOffsetMilliseconds,
            selectedMediaID: nil,
            placeholder: placeholder
        )
    }

    func playLiveTV(
        channel: PlexLiveChannel,
        program: PlexLiveProgram?,
        lineup: PlexLiveTVLineup
    ) async {
        let attemptID = UUID()
        let subtitle = [channel.displayNumber, channel.displayTitle]
            .compactMap { $0 }
            .joined(separator: " · ")
        enterLoadingState(
            placeholder: PlaybackPlaceholder(
                title: program?.displayTitle ?? channel.displayTitle,
                subtitle: subtitle,
                posterPath: nil,
                backdropPath: program?.preferredLandscapePath ?? channel.thumb,
                artwork: .liveChannel(logoPath: channel.thumb)
            ),
            attemptID: attemptID
        )

        do {
            let tune = try await plexService.tuneLiveTV(
                provider: lineup.provider,
                channel: channel
            )
            guard currentPlaybackAttemptID == attemptID else { return }

            let resolver = StreamResolver.evaluateLiveTV(
                media: tune.media,
                forceAVPlayer: preferences.forceAVPlayer,
                forceVLCKit: preferences.forceVLCKit
            )
            let newEngine = PlaybackEngineFactory.makeEngine(type: resolver.engine)
            newEngine.configureVideoEnhancement(.disabled)
            newEngine.onPlaybackEnded = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handlePlaybackEnded()
                }
            }
            newEngine.setPictureInPictureDelegate(self)

            let title = program?.displayTitle ?? channel.displayTitle
            let context = PlaybackAttemptContext(
                attemptID: attemptID,
                title: title,
                ratingKey: program?.ratingKey ?? tune.sessionID,
                engine: resolver.engine,
                resolverReason: resolver.reason,
                mediaID: tune.media.id,
                partID: tune.part.id,
                sanitizedPlaybackURL: plexService.sanitizedPlaybackURLString(for: tune.playbackURL)
            )
            let liveContext = PlexLivePlaybackContext(
                lineup: lineup,
                channel: channel,
                program: program,
                sessionID: tune.sessionID
            )

            hasScrobbled = false
            didFinalizeCurrentSession = false
            lastReportedTimeMs = 0
            lastReportedDurationMs = 0
            ratingKey = program?.ratingKey ?? tune.sessionID
            activePlaybackServerID = plexService.currentServerIdentifier
            activePlaybackUsesLocalDownload = false
            activePlaybackSessionIdentifier = tune.playbackSessionIdentifier
            activeTranscodeSessionID = tune.transcodeSessionID
            activeItemDetails = nil
            activeLiveTVContext = liveContext
            engine = newEngine
            playbackSource = PlaybackSource(
                url: tune.playbackURL,
                startPosition: nil,
                context: context,
                preferredAudioTrackPosition: nil,
                locality: sourceLocality(for: tune.playbackURL),
                liveTVContext: liveContext
            )
            debugInfo = PlaybackDebugInfo(
                title: title,
                engine: resolver.engine,
                decision: .liveTV,
                media: tune.media,
                part: tune.part,
                attemptID: attemptID,
                resolverReason: resolver.reason,
                sanitizedPlaybackURL: context.sanitizedPlaybackURL
            )
            playerPresentationID = UUID()
            nowPlayingController.beginLiveSession(
                title: title,
                channelTitle: subtitle,
                artworkPath: program?.preferredLandscapePath ?? channel.thumb,
                engine: newEngine,
                plexService: plexService,
                skipBackwardInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
                skipForwardInterval: preferences.playerDoubleTapForwardInterval.timeInterval
            )
            startTimelineReporting()
            startLiveTVScheduleRefresh()
        } catch {
            guard currentPlaybackAttemptID == attemptID else { return }
            loadError = error.localizedDescription
        }
    }

    // MARK: - Live TV Schedule

    /// Keeps the tuned channel's schedule current for the whole session. The
    /// lineup handed to `playLiveTV` is a snapshot — the home shelf carries
    /// only what was airing when it loaded — so without this the play bar and
    /// the header would still be describing a finished program an hour later.
    private func startLiveTVScheduleRefresh() {
        liveTVScheduleRefreshTask?.cancel()
        guard let sessionID = activeLiveTVContext?.sessionID else { return }

        liveTVScheduleRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeLiveTVContext?.sessionID == sessionID else { return }
                await self.refreshLiveTVSchedule()
                guard !Task.isCancelled,
                      self.activeLiveTVContext?.sessionID == sessionID else { return }
                try? await Task.sleep(for: .seconds(self.liveTVScheduleRefreshDelay))
            }
        }
    }

    func cancelLiveTVScheduleRefresh() {
        liveTVScheduleRefreshTask?.cancel()
        liveTVScheduleRefreshTask = nil
    }

    /// Wakes up just after the current program ends so the switchover is
    /// prompt, and is bounded so a missing or stale schedule still re-checks on
    /// its own.
    private var liveTVScheduleRefreshDelay: TimeInterval {
        let programEnd = activeLiveTVContext?.program(at: .now)?.endsAt
        let delay = programEnd.map { $0.timeIntervalSinceNow + 5 } ?? 0
        return min(max(delay, 60), 15 * 60)
    }

    /// Re-derives the airing program, fetching a fresh grid only once the
    /// schedule Dusk already holds stops covering the near future.
    private func refreshLiveTVSchedule() async {
        guard let context = activeLiveTVContext else { return }

        var programs = context.channelPrograms
        let coverage = programs.compactMap(\.endsAt).max() ?? .distantPast
        if coverage < Date.now.addingTimeInterval(Self.liveTVScheduleCoverageHorizon) {
            let fetched = await fetchLiveTVSchedule(
                provider: context.lineup.provider,
                channel: context.channel
            )
            guard activeLiveTVContext?.sessionID == context.sessionID else { return }
            if !fetched.isEmpty {
                programs = fetched
            }
        }

        guard !programs.isEmpty else { return }
        let refreshed = context.replacingChannelPrograms(programs)
        guard refreshed != activeLiveTVContext else { return }
        activeLiveTVContext = refreshed

        if let title = refreshed.program(at: .now)?.displayTitle {
            nowPlayingController.updateLiveProgramTitle(title)
        }
    }

    private func fetchLiveTVSchedule(
        provider: PlexLiveTVProvider,
        channel: PlexLiveChannel
    ) async -> [PlexLiveProgram] {
        var programs = await liveTVGuidePrograms(provider: provider, channel: channel, date: .now)
        // Plex's grid is queried a day at a time, so a session running into the
        // evening outlives today's schedule. Pull tomorrow in as well.
        let coverage = programs.compactMap(\.endsAt).max() ?? .distantPast
        if coverage < Date.now.addingTimeInterval(Self.liveTVScheduleCoverageHorizon),
           let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) {
            programs += await liveTVGuidePrograms(
                provider: provider,
                channel: channel,
                date: tomorrow
            )
        }
        return programs.sorted { ($0.beginsAt ?? .distantPast) < ($1.beginsAt ?? .distantPast) }
    }

    private func liveTVGuidePrograms(
        provider: PlexLiveTVProvider,
        channel: PlexLiveChannel,
        date: Date
    ) async -> [PlexLiveProgram] {
        let lineup = try? await plexService.getLiveTVGuide(
            provider: provider,
            channels: [channel],
            date: date
        )
        return lineup?.guides.first?.programs ?? []
    }

    /// How far ahead the held schedule must reach before Dusk refetches it.
    private static let liveTVScheduleCoverageHorizon: TimeInterval = 60 * 60

    func playFromStart(ratingKey: String, placeholder: PlaybackPlaceholder? = nil) async {
        await beginPlayback(
            ratingKey: ratingKey,
            startPositionOverride: 0,
            resumeOffsetMilliseconds: nil,
            selectedMediaID: nil,
            placeholder: placeholder
        )
    }

    func playVersion(
        ratingKey: String,
        mediaID: Int,
        resumeOffsetMilliseconds: Int?,
        placeholder: PlaybackPlaceholder? = nil
    ) async {
        await beginPlayback(
            ratingKey: ratingKey,
            startPositionOverride: nil,
            resumeOffsetMilliseconds: resumeOffsetMilliseconds,
            selectedMediaID: mediaID,
            placeholder: placeholder
        )
    }

    /// Present the cover on a loading placeholder first, then prepare the session
    /// in the background so pressing Play feels instant.
    private func beginPlayback(
        ratingKey: String,
        startPositionOverride: TimeInterval?,
        resumeOffsetMilliseconds: Int?,
        selectedMediaID: Int?,
        placeholder: PlaybackPlaceholder?
    ) async {
        let attemptID = UUID()
        enterLoadingState(placeholder: placeholder, attemptID: attemptID)

        let didStart = await startPlaybackSession(
            ratingKey: ratingKey,
            startPositionOverride: startPositionOverride,
            resumeOffsetMilliseconds: resumeOffsetMilliseconds,
            selectedMediaID: selectedMediaID,
            attemptID: attemptID
        )

        // A newer attempt or a dismissal superseded this one while it loaded.
        guard currentPlaybackAttemptID == attemptID else { return }

        if didStart {
            resetContinuousPlayEpisodeRunCountForCurrentItem()
        } else {
            // `startPlaybackSession` set `loadError`; the cover surfaces it as an
            // alert (see PlayerView) and stays up on the placeholder until the
            // user dismisses it.
            continuousPlayEpisodeRunCount = 0
        }
    }

    /// Opens the player cover on a loading placeholder and marks the start of a
    /// new playback attempt. Any live session (e.g. a Picture in Picture window)
    /// is finalized first so it does not leak, then its engine is dropped so the
    /// loading state shows instead of the outgoing video.
    private func enterLoadingState(placeholder: PlaybackPlaceholder?, attemptID: UUID) {
        if engine != nil {
            finalizeCurrentPlaybackSession(markCompleted: false)
        }

        currentPlaybackAttemptID = attemptID
        loadError = nil
        qualitySwitchError = nil
        loadingPlaceholder = placeholder
        cancelUpNextCountdown()
        cancelUpNextPosterCountdown()
        upNextPresentation = nil
        upNextPoster = nil

        engine?.onPlaybackEnded = nil
        engine?.setPictureInPictureDelegate(nil)
        engine = nil
        playbackSource = nil
        debugInfo = nil
        activeItemDetails = nil
        cancelLiveTVScheduleRefresh()
        activeLiveTVContext = nil
        ratingKey = nil
        isPictureInPictureActive = false
        pendingPictureInPictureRestoreCompletion = nil

        playerPresentationID = UUID()
        showPlayer = true
    }

    /// Dismisses the player cover after a load-error alert. Teardown runs through
    /// the cover's `onDismiss` (`onPlayerDismissed` → `clearPlayerState`).
    func dismissFailedPlayback() {
        showPlayer = false
    }

    /// Called when the full-screen player cover is dismissed.
    /// Sends a final "stopped" timeline, scrobbles if needed, and tears down.
    func onPlayerDismissed() {
        // The cover is also dismissed when PiP takes over (so the floating window
        // is unobstructed). In that case keep the session alive — teardown
        // happens when the PiP window itself closes (see the PiP delegate).
        if isPictureInPictureActive {
            return
        }
        cancelUpNextCountdown()
        finalizeCurrentPlaybackSession(markCompleted: false)
        clearPlayerState()
        showPlayer = false
    }

    /// Dismiss any loading error so the UI can return to normal.
    func clearError() {
        loadError = nil
    }

    func resetContinuousPlayEpisodeRunCountForCurrentItem() {
        continuousPlayEpisodeRunCount = activeItemDetails?.type == .episode ? 1 : 0
    }

    /// Records the live play/pause state so the Up Next poster countdown can
    /// freeze while the user pauses during the credits.
    func noteActivePlaybackState(_ state: PlaybackState) {
        latestActivePlaybackState = state

        let shouldSuppress: Bool
        switch state {
        case .loading, .playing:
            shouldSuppress = true
        case .idle, .paused, .stopped, .error:
            shouldSuppress = false
        }
        if isIdleTimerSuppressed != shouldSuppress {
            isIdleTimerSuppressed = shouldSuppress
        }
    }
}

// MARK: - Picture in Picture

/// Picture in Picture lifecycle handling.
///
/// The full-screen player cover is dropped while PiP is active so the floating
/// window is unobstructed; the engine outlives the cover because
/// `onPlayerDismissed` and `PlayerViewModel.cleanup` both check
/// `isPictureInPictureActive`. Returning to the app re-presents the cover over
/// the still-live engine — `PlayerViewModel.startPlaybackIfNeeded` skips the
/// reload so playback continues from where the window left it.
extension PlaybackCoordinator: PlaybackPictureInPictureDelegate {
    func pictureInPictureActiveDidChange(_ isActive: Bool) {
        isPictureInPictureActive = isActive

        if isActive {
            // Hide the cover so the floating window stands alone. Teardown is
            // suppressed in onPlayerDismissed while this flag is set.
            if showPlayer {
                showPlayer = false
            }
        } else if !showPlayer {
            // PiP closed while the player UI was dismissed and no restore was
            // requested (e.g. AVKit's close button). Finalize the session as if
            // the player had been dismissed normally.
            cancelUpNextCountdown()
            finalizeCurrentPlaybackSession(markCompleted: false)
            clearPlayerState()
        }
    }

    func pictureInPictureRestorePlayerUI(completion: @escaping (Bool) -> Void) {
        guard !showPlayer else {
            completion(true)
            return
        }

        pendingPictureInPictureRestoreCompletion = completion
        showPlayer = true

        // Safety net: if the re-presented player never reports back, release the
        // system's restore handshake anyway so PiP can finish stopping.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            self?.flushPendingPictureInPictureRestoreCompletion()
        }
    }

    /// Called by the player view once it is back on screen so AVKit can animate
    /// the video out of the PiP window and into the player.
    func notePlayerUIDidAppear() {
        flushPendingPictureInPictureRestoreCompletion()
    }

    private func flushPendingPictureInPictureRestoreCompletion() {
        guard let completion = pendingPictureInPictureRestoreCompletion else { return }
        pendingPictureInPictureRestoreCompletion = nil
        completion(true)
    }
}
