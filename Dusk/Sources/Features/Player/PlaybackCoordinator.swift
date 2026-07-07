import Foundation
import SwiftUI

/// Orchestrates the "play an item" flow: fetch metadata → resolve engine →
/// construct URL → present player → report timeline → scrobble.
///
/// Injected into the environment so any view can trigger playback via
/// `coordinator.play(ratingKey:)`. The player is presented as a full-screen
/// cover in MainTabView.
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
    var upNextPresentation: UpNextPresentation?
    /// The small bottom-right "next episode" poster shown over the play bar once
    /// the credits marker is reached (replaces the old Skip Credits button). Nil
    /// when not in credits, when there is no next episode, or while the
    /// full-screen `upNextPresentation` is showing instead.
    var upNextPoster: UpNextPosterPresentation?
    var isSwitchingQuality = false
    var qualitySwitchError: String?
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

    @ObservationIgnored nonisolated(unsafe) var timelineTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var upNextCountdownTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var upNextPosterCountdownTask: Task<Void, Never>?
    /// One-shot per attempt: observes the engine after an online direct-play
    /// start and swaps the session to the server-stream ladder rung when the
    /// engine fails. Cancelled on finalize/clear/engine swap.
    @ObservationIgnored nonisolated(unsafe) var directPlayFallbackWatchTask: Task<Void, Never>?

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
    }

    // MARK: - Play an Item

    /// Full "play an item" flow. The player cover is presented immediately on a
    /// loading placeholder, then metadata is fetched → engine picked → URL built
    /// → session committed under the already-visible cover. `placeholder` is what
    /// the caller already knows (title/poster) so the loading screen isn't blank.
    func play(ratingKey: String, placeholder: PlaybackPlaceholder? = nil) async {
        await beginPlayback(
            ratingKey: ratingKey,
            startPositionOverride: nil,
            selectedMediaID: nil,
            placeholder: placeholder
        )
    }

    func playFromStart(ratingKey: String, placeholder: PlaybackPlaceholder? = nil) async {
        await beginPlayback(
            ratingKey: ratingKey,
            startPositionOverride: 0,
            selectedMediaID: nil,
            placeholder: placeholder
        )
    }

    func playVersion(ratingKey: String, mediaID: Int, placeholder: PlaybackPlaceholder? = nil) async {
        await beginPlayback(
            ratingKey: ratingKey,
            startPositionOverride: nil,
            selectedMediaID: mediaID,
            placeholder: placeholder
        )
    }

    /// Present the cover on a loading placeholder first, then prepare the session
    /// in the background so pressing Play feels instant.
    private func beginPlayback(
        ratingKey: String,
        startPositionOverride: TimeInterval?,
        selectedMediaID: Int?,
        placeholder: PlaybackPlaceholder?
    ) async {
        let attemptID = UUID()
        enterLoadingState(placeholder: placeholder, attemptID: attemptID)

        let didStart = await startPlaybackSession(
            ratingKey: ratingKey,
            startPositionOverride: startPositionOverride,
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
