#if os(tvOS)
import Foundation
import Testing
import UIKit
@testable import Dusk

/// Serialized because the idle-timer flag is shared by every player in the app.
@Suite("tvOS playback idle timer", .serialized)
@MainActor
struct PlaybackIdleTimerTests {
    @Test func pauseStopErrorAndLoadingReleaseSleepUntilPlaybackResumes() {
        let previousValue = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = previousValue }
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true

        for state: PlaybackState in [.paused, .stopped, .error, .idle, .loading] {
            playback.noteActivePlaybackState(.playing)
            #expect(UIApplication.shared.isIdleTimerDisabled)

            playback.noteActivePlaybackState(state)
            #expect(!playback.isIdleTimerSuppressed)
            #expect(!UIApplication.shared.isIdleTimerDisabled)
        }

        playback.noteActivePlaybackState(.playing)
        #expect(UIApplication.shared.isIdleTimerDisabled)
        playback.onPlayerDismissed()
        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }

    @Test func repeatedSnapshotRepairsAnIndependentVLCKitWrite() {
        let previousValue = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = previousValue }
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        playback.noteActivePlaybackState(.paused)

        // A library callback can change UIKit without changing Dusk's Bool.
        UIApplication.shared.isIdleTimerDisabled = true
        playback.noteActivePlaybackState(.paused)
        #expect(!UIApplication.shared.isIdleTimerDisabled)

        playback.noteActivePlaybackState(.playing)
        UIApplication.shared.isIdleTimerDisabled = false
        playback.noteActivePlaybackState(.playing)
        #expect(UIApplication.shared.isIdleTimerDisabled)
        playback.onPlayerDismissed()
    }

    @Test func finalizedEpisodeIgnoresLatePlayingSnapshots() {
        let previousValue = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = previousValue }
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        playback.noteActivePlaybackState(.playing)

        playback.finalizeCurrentPlaybackSession(markCompleted: true)
        #expect(!UIApplication.shared.isIdleTimerDisabled)
        UIApplication.shared.isIdleTimerDisabled = true
        playback.noteActivePlaybackState(.playing)
        #expect(!UIApplication.shared.isIdleTimerDisabled)

        playback.clearPlayerState()
        playback.noteActivePlaybackState(.playing)
        #expect(UIApplication.shared.isIdleTimerDisabled)
        playback.dismissFailedPlayback()
        #expect(!UIApplication.shared.isIdleTimerDisabled)
        playback.noteActivePlaybackState(.playing)
        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }

    @Test func upNextWaitingCountdownAndFailureAllowSleep() throws {
        let previousValue = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = previousValue }
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        let episode = try JSONDecoder().decode(
            PlexEpisode.self,
            from: Data(#"{"ratingKey":"2","key":"/library/metadata/2","title":"Next episode"}"#.utf8)
        )

        for shouldAutoplay in [false, true] {
            playback.upNextPresentation = UpNextPresentation(
                item: PlaybackQueueItem(episode: episode),
                source: .playbackEnded,
                shouldAutoplay: shouldAutoplay,
                countdownDuration: 10,
                countdownStartedAt: shouldAutoplay ? .now : nil,
                secondsRemaining: shouldAutoplay ? 0 : nil,
                autoplayProgress: shouldAutoplay ? 1 : nil,
                autoplayBlockedByPassoutProtection: !shouldAutoplay,
                passoutProtectionEpisodeLimit: 3,
                errorMessage: shouldAutoplay ? "Could not start the next episode." : nil
            )
            UIApplication.shared.isIdleTimerDisabled = true
            playback.noteActivePlaybackState(.playing)
            #expect(!UIApplication.shared.isIdleTimerDisabled)
        }
        playback.onPlayerDismissed()
    }
}
#endif
