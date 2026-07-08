import Foundation
import SwiftUI

extension PlayerViewModel {
    /// Fallback credits estimate tunables (see `estimatedCreditsMarker`). The cap
    /// is the main guardrail — 3 minutes is about as early as the poster can
    /// appear before it risks spoiling that the episode is nearly over. Bump
    /// `estimatedCreditsMaxLeadMs` alone to give more runway.
    static let estimatedCreditsLeadFraction = 0.10
    static let estimatedCreditsMinLeadMs: Double = 90_000
    static let estimatedCreditsMaxLeadMs: Double = 180_000

    var displayPosition: TimeInterval {
        isScrubbing ? scrubPosition : currentTime
    }

    /// The actionable intro marker at the current position, surfaced as the
    /// "Skip Intro" button. Credits are handled by the Up Next poster instead of
    /// a skip button, so they are deliberately excluded here.
    var activeSkipMarker: PlexMarker? {
        let positionMs = Int(displayPosition * 1000)
        return markers.first {
            $0.isIntro && $0.skipButtonTitle != nil && $0.contains(positionMs: positionMs)
        }
    }

    /// The credits marker once its start has been reached. Unlike
    /// `activeSkipMarker` it stays non-nil past the marker's end (through the
    /// rest of the episode), and only clears if the user seeks back before the
    /// credits start — matching the Up Next poster's "appears at the credits and
    /// stays until the episode ends" lifetime. Based on actual playback time so
    /// scrubbing previews don't flicker it.
    var reachedCreditsMarker: PlexMarker? {
        guard duration > 0 else { return nil }
        let positionMs = Int(currentTime * 1000)

        // Prefer Plex's own credits marker whenever it exists.
        if let credits = markers.first(where: { $0.isCredits }) {
            return positionMs >= credits.startTimeOffset ? credits : nil
        }

        // Plex shipped no credits marker for this item. Fall back to an estimated
        // one so the Up Next poster still appears in the home stretch — flagged
        // `isEstimated` so it can never auto-skip or auto-advance.
        guard let estimated = estimatedCreditsMarker,
              positionMs >= estimated.startTimeOffset else { return nil }
        return estimated
    }

    /// Synthesized credits marker for items Plex has no marker for. Tuned
    /// generous: the poster is a small corner affordance the user can ignore, so
    /// appearing a little early costs nothing while appearing too late misses the
    /// point. Spans `duration − clamp(10% of duration, 1.5 min, 3 min)` to the
    /// end. Never added to `markers`, so it can't surface a "Skip" button (which
    /// only intros do).
    private var estimatedCreditsMarker: PlexMarker? {
        guard duration > 0 else { return nil }
        let durationMs = duration * 1000
        let leadMs = min(
            max(durationMs * Self.estimatedCreditsLeadFraction, Self.estimatedCreditsMinLeadMs),
            Self.estimatedCreditsMaxLeadMs
        )
        let startMs = Int((durationMs - leadMs).rounded())
        return PlexMarker(
            id: PlexMarker.estimatedCreditsID,
            type: "credits",
            startTimeOffset: startMs,
            endTimeOffset: Int(durationMs.rounded()),
            isEstimated: true
        )
    }

    var shouldShowBufferingIndicator: Bool {
        // The standard spinner also covers the whole startup (load +
        // VLCKit audio warmup) so the loading presentation lives in one
        // place; the timed `showBufferingIndicator` handles mid-play
        // rebuffering as before.
        (showBufferingIndicator || isAwaitingPlaybackStart) && playbackError == nil
    }

    /// True until playback has genuinely started: covers the load itself and
    /// the VLCKit audio warmup, which masks the whole bring-up (including
    /// the pause→resume audio cure) as `.loading`. The player controls hide
    /// the center play/pause button while this holds, so the button never
    /// appears in a state it would immediately flip out of.
    var isAwaitingPlaybackStart: Bool {
        (state == .idle || state == .loading) && playbackError == nil
    }

    var shouldDisableIdleTimer: Bool {
        guard playbackError == nil else { return false }

        switch state {
        case .idle:
            return hasLoadedSource
        case .loading, .playing:
            return true
        case .paused, .stopped, .error:
            return false
        }
    }

    var selectedAudioTrack: AudioTrack? {
        audioTracks.first { $0.id == selectedAudioTrackID }
    }

    var selectedSubtitleTrack: SubtitleTrack? {
        subtitleTracks.first { $0.id == selectedSubtitleTrackID }
    }

    var formattedTime: String {
        formatTime(displayPosition)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
