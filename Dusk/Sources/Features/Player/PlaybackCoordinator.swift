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

    let plexService: PlexService
    let preferences: UserPreferences
    var ratingKey: String?
    var activeItemDetails: PlexMediaDetails?
    var hasScrobbled = false
    var didFinalizeCurrentSession = false
    var isHandlingPlaybackEnded = false
    var lastReportedTimeMs = 0
    var lastReportedDurationMs = 0
    var continuousPlayEpisodeRunCount = 0

    @ObservationIgnored nonisolated(unsafe) var timelineTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var upNextCountdownTask: Task<Void, Never>?

    init(plexService: PlexService, preferences: UserPreferences = UserPreferences()) {
        self.plexService = plexService
        self.preferences = preferences
    }

    deinit {
        timelineTimer?.invalidate()
    }

    // MARK: - Play an Item

    /// Full "play an item" flow: fetch details → pick engine → build URL → present.
    func play(ratingKey: String) async {
        isLoading = true
        defer { isLoading = false }

        let didStart = await startPlaybackSession(
            ratingKey: ratingKey,
            startPositionOverride: nil,
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
