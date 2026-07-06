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
    var isLoading = false
    var loadError: String?
    var engine: (any PlaybackEngine)?
    var debugInfo: PlaybackDebugInfo?
    var playbackSource: PlaybackSource?
    var playerPresentationID = UUID()
    var upNextPresentation: UpNextPresentation?
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

    @ObservationIgnored nonisolated(unsafe) var timelineTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var upNextCountdownTask: Task<Void, Never>?
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
    }

    // MARK: - Play an Item

    /// Full "play an item" flow: fetch details → pick engine → build URL → present.
    func play(ratingKey: String) async {
        isLoading = true
        defer { isLoading = false }

        let didStart = await startPlaybackSession(
            ratingKey: ratingKey,
            startPositionOverride: nil,
            selectedMediaID: nil,
            presentPlayer: true
        )
        if didStart {
            resetContinuousPlayEpisodeRunCountForCurrentItem()
        } else {
            continuousPlayEpisodeRunCount = 0
        }
    }

    func playFromStart(ratingKey: String) async {
        isLoading = true
        defer { isLoading = false }

        let didStart = await startPlaybackSession(
            ratingKey: ratingKey,
            startPositionOverride: 0,
            selectedMediaID: nil,
            presentPlayer: true
        )
        if didStart {
            resetContinuousPlayEpisodeRunCountForCurrentItem()
        } else {
            continuousPlayEpisodeRunCount = 0
        }
    }

    func playVersion(ratingKey: String, mediaID: Int) async {
        isLoading = true
        defer { isLoading = false }

        let didStart = await startPlaybackSession(
            ratingKey: ratingKey,
            startPositionOverride: nil,
            selectedMediaID: mediaID,
            presentPlayer: true
        )
        if didStart {
            resetContinuousPlayEpisodeRunCountForCurrentItem()
        } else {
            continuousPlayEpisodeRunCount = 0
        }
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
