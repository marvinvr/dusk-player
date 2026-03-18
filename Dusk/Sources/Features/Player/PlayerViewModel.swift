import Foundation
import SwiftUI

struct PlayerSeekFeedbackPresentation: Equatable {
    enum Direction: Equatable {
        case backward
        case forward

        var symbolName: String {
            switch self {
            case .backward:
                return "gobackward"
            case .forward:
                return "goforward"
            }
        }
    }

    let direction: Direction
    let seconds: Int
    let trigger: Int
}

/// Manages player UI state: syncs from the engine via timer, handles overlay
/// visibility, scrubbing, and forwards control actions to the engine.
@MainActor @Observable
final class PlayerViewModel {
    var state: PlaybackState = .idle
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isBuffering = false
    var hasStartedPlayback = false
    var playbackError: PlaybackError?
    var subtitleTracks: [SubtitleTrack] = []
    var audioTracks: [AudioTrack] = []
    var selectedSubtitleTrackID: Int?
    var selectedAudioTrackID: Int?
    var showControls = true
    var showSubtitlePicker = false
    var showAudioPicker = false
    var isScrubbing = false
    var scrubPosition: TimeInterval = 0
    var seekFeedback: PlayerSeekFeedbackPresentation?
    var autoSkipCountdownProgress: Double?

    let engine: any PlaybackEngine
    let engineView: AnyView
    let markers: [PlexMarker]
    var hasLoadedSource = false
    var sourcePart: PlexMediaPart?
    var preferredSubtitleLanguage: String?
    var preferredAudioLanguage: String?
    var subtitleForcedOnly = false
    var autoSkipIntro = true
    var autoSkipCredits = false
    var autoSkipCountdownMarkerID: Int?
    var autoSkipHandler: (@MainActor (PlexMarker) -> Void)?
    var hasConfiguredAutomaticTrackSelection = false
    var hasAppliedAutomaticAudioSelection = false
    var hasAppliedAutomaticSubtitleSelection = false
    var pendingPlaybackState: PlaybackState?
    var pendingPlaybackStateExpiration: Date?
    @ObservationIgnored nonisolated(unsafe) var syncTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var hideTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var seekFeedbackTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var autoSkipCountdownTask: Task<Void, Never>?

    init(engine: any PlaybackEngine, markers: [PlexMarker] = []) {
        self.engine = engine
        self.engineView = engine.makePlayerView()
        self.markers = markers.sorted { $0.startTimeOffset < $1.startTimeOffset }
        startSync()
        scheduleHide()
    }

    deinit {
        syncTimer?.invalidate()
        hideTimer?.invalidate()
        seekFeedbackTask?.cancel()
        autoSkipCountdownTask?.cancel()
    }

    func cleanup() {
        syncTimer?.invalidate()
        hideTimer?.invalidate()
        seekFeedbackTask?.cancel()
        autoSkipCountdownTask?.cancel()
        syncTimer = nil
        hideTimer = nil
        seekFeedbackTask = nil
        autoSkipCountdownTask = nil
        // Pause (not stop) so the coordinator can read final position
        // for timeline reporting before tearing down the engine.
        engine.pause()
    }

    func configureAutomaticTrackSelection(
        preferences: UserPreferences,
        part: PlexMediaPart?
    ) {
        sourcePart = part
        preferredSubtitleLanguage = Self.normalizedLanguageCode(preferences.defaultSubtitleLanguage)
        preferredAudioLanguage = Self.normalizedLanguageCode(preferences.defaultAudioLanguage)
        subtitleForcedOnly = preferences.subtitleForcedOnly
        autoSkipIntro = preferences.autoSkipIntro
        autoSkipCredits = preferences.autoSkipCredits
        hasConfiguredAutomaticTrackSelection = true
        hasAppliedAutomaticAudioSelection = false
        hasAppliedAutomaticSubtitleSelection = false
        syncTrackLists()
        applyAutomaticTrackSelectionIfNeeded()
    }

    func startPlaybackIfNeeded(source: PlaybackSource) {
        guard !hasLoadedSource else { return }
        hasLoadedSource = true
        engine.load(source: source)
    }
}
