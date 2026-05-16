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
        showBufferingIndicator && playbackError == nil
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
