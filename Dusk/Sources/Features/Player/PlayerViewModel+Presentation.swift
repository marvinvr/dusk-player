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

    var isLiveTV: Bool {
        liveTVContext != nil
    }

    /// What the play bar spans. A live session shows the scheduled program the
    /// playhead sits in (mapped onto the engine clock) rather than the HLS
    /// window, whose bounds slide on every playlist reload — seeking stays
    /// clamped to what the session can actually reach, see
    /// `clampedSeekPosition`.
    var timelineRange: ClosedRange<TimeInterval> {
        if let liveTimeline {
            return liveTimeline.positionRange
        }
        if let seekableRange {
            return seekableRange
        }
        return 0...max(duration, 0)
    }

    /// Fractions of the play bar the tuned session can still be rewound into,
    /// ending at the live edge. Nil until a live session is under way.
    var liveReachableTrackRange: ClosedRange<Double>? {
        guard let liveTimeline, let seekableRange else { return nil }
        let start = timelineProgress(for: seekableRange.lowerBound)
        let end = timelineProgress(for: liveTimeline.livePosition)
        guard end > start else { return nil }
        return start...end
    }

    var timelineProgress: Double {
        timelineProgress(for: displayPosition)
    }

    func timelineProgress(for position: TimeInterval) -> Double {
        let range = timelineRange
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((position - range.lowerBound) / span, 0), 1)
    }

    func timelinePosition(for progress: Double) -> TimeInterval {
        let range = timelineRange
        return range.lowerBound + (range.upperBound - range.lowerBound) * min(max(progress, 0), 1)
    }

    /// True while the viewer is watching the live edge. Measured against the
    /// projected live edge (see `LiveEdgeClock`) rather than the HLS seekable
    /// bound, which steps by a segment at a time and used to flip this — and
    /// the readout below — back and forth several times a minute.
    var isAtLiveEdge: Bool {
        // A live session that has not produced a snapshot yet is still starting
        // up, and playback always starts at the edge — reading it as "behind"
        // would offer a Go Live jump with nowhere to jump to.
        guard let liveTimeline else { return isLiveTV }
        return liveTimeline.isAtLiveEdge(atPosition: displayPosition)
    }

    var formattedLiveOffset: String {
        guard let liveTimeline else { return "LIVE" }
        let behind = liveTimeline.secondsBehindLive(atPosition: displayPosition)
        guard behind >= LiveTimelineSnapshot.liveEdgeTolerance else { return "LIVE" }

        let secondsBehind = Int(behind.rounded())
        let hours = secondsBehind / 3600
        let minutes = (secondsBehind % 3600) / 60
        let seconds = secondsBehind % 60
        return hours > 0
            ? String(format: "−%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "−%d:%02d", minutes, seconds)
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

    /// True until playback has genuinely started: covers the load itself and
    /// the VLCKit audio warmup, which masks the whole bring-up (including
    /// the pause→resume audio cure) as `.loading`. The player controls hide
    /// the center play/pause button while this holds, so the button never
    /// appears in a state it would immediately flip out of.
    var isAwaitingPlaybackStart: Bool {
        (state == .idle || state == .loading) && playbackError == nil
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
