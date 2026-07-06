import Foundation
import SwiftUI

extension PlayerViewModel {
    var displayPosition: TimeInterval {
        isScrubbing ? scrubPosition : currentTime
    }

    var activeSkipMarker: PlexMarker? {
        let positionMs = Int(displayPosition * 1000)
        return markers.first {
            $0.skipButtonTitle != nil && $0.contains(positionMs: positionMs)
        }
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
