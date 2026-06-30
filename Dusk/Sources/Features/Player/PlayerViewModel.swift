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
    var showBufferingIndicator = false
    var hasStartedPlayback = false
    var playbackError: PlaybackError?
    var videoEnhancementStatus: VideoEnhancementStatus = .disabled
    var subtitleTracks: [SubtitleTrack] = []
    var audioTracks: [AudioTrack] = []
    var selectedSubtitleTrackID: Int?
    var selectedAudioTrackID: Int?
    var showControls = true
    var aspectFillEnabled = false
    var showSubtitlePicker = false
    var showAudioPicker = false
    var showQualityPicker = false
    var showPlaybackInfo = false
    var isControlsInteractionHeld = false
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
    var autoSkipIntroMode: AutoSkipIntroMode = .alwaysExceptFirstEpisode
    var autoSkipCredits = false
    var isFirstEpisodeInSeason = false
    var autoSkipCountdownMarkerID: Int?
    var autoSkipHandler: (@MainActor (PlexMarker) -> Void)?
    var hasConfiguredAutomaticTrackSelection = false
    var hasAppliedAutomaticAudioSelection = false
    var hasAppliedAutomaticSubtitleSelection = false
    var pendingPlaybackState: PlaybackState?
    var pendingPlaybackStateExpiration: Date?
    var playbackSnapshotHandler: (@MainActor (PlaybackState, TimeInterval, TimeInterval) -> Void)?
    var bufferingStartedAt: Date?
    var stalledPlaybackStartedAt: Date?
    var lastProgressAt = Date()
    var lastProgressPosition: TimeInterval = 0
    var stallRecoveryAttempts = 0
    var lastStallRecoveryAt: Date?
    @ObservationIgnored nonisolated(unsafe) var syncTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var controlsAutoHideTask: Task<Void, Never>?
    @ObservationIgnored var controlsAutoHideDeadline: Date?
    @ObservationIgnored var controlsInteractionHoldCount = 0
    @ObservationIgnored var suppressSeekPointSelectUntil: Date?
    @ObservationIgnored nonisolated(unsafe) var seekFeedbackTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var autoSkipCountdownTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var markerSkipTask: Task<Void, Never>?

    init(engine: any PlaybackEngine, markers: [PlexMarker] = []) {
        self.engine = engine
        self.engineView = engine.makePlayerView()
        self.markers = markers.sorted { $0.startTimeOffset < $1.startTimeOffset }
        startSync()
    }

    deinit {
        syncTimer?.invalidate()
        controlsAutoHideTask?.cancel()
        seekFeedbackTask?.cancel()
        autoSkipCountdownTask?.cancel()
        markerSkipTask?.cancel()
    }

    func cleanup() {
        syncTimer?.invalidate()
        controlsAutoHideTask?.cancel()
        seekFeedbackTask?.cancel()
        autoSkipCountdownTask?.cancel()
        markerSkipTask?.cancel()
        syncTimer = nil
        controlsAutoHideTask = nil
        controlsAutoHideDeadline = nil
        controlsInteractionHoldCount = 0
        isControlsInteractionHeld = false
        suppressSeekPointSelectUntil = nil
        seekFeedbackTask = nil
        autoSkipCountdownTask = nil
        markerSkipTask = nil
        showBufferingIndicator = false
        showQualityPicker = false
        bufferingStartedAt = nil
        stalledPlaybackStartedAt = nil
        // Pause (not stop) so the coordinator can read final position
        // for timeline reporting before tearing down the engine. While a PiP
        // window is showing, the cover is dismissed but playback must keep
        // running in the floating window, so leave the engine alone.
        if !engine.isPictureInPictureActive {
            engine.pause()
        }
    }

    func configureAutomaticTrackSelection(
        preferences: UserPreferences,
        part: PlexMediaPart?,
        mediaDetails: PlexMediaDetails? = nil
    ) {
        sourcePart = part
        preferredSubtitleLanguage = Self.normalizedLanguageCode(preferences.defaultSubtitleLanguage)
        preferredAudioLanguage = Self.normalizedLanguageCode(preferences.defaultAudioLanguage)
        subtitleForcedOnly = preferences.subtitleForcedOnly
        autoSkipIntroMode = preferences.autoSkipIntroMode
        autoSkipCredits = preferences.autoSkipCredits
        isFirstEpisodeInSeason = mediaDetails?.type == .episode && mediaDetails?.index == 1
        hasConfiguredAutomaticTrackSelection = true
        hasAppliedAutomaticAudioSelection = false
        hasAppliedAutomaticSubtitleSelection = false
        syncTrackLists()
        applyAutomaticTrackSelectionIfNeeded()
    }

    func startPlaybackIfNeeded(source: PlaybackSource) {
        guard !hasLoadedSource else { return }
        hasLoadedSource = true
        // Returning from a PiP window re-presents the player over the same live
        // engine; loading again would restart playback from the top. Only load
        // a fresh engine that has not begun playing yet.
        guard engine.state == .idle else { return }
        engine.load(source: source)
    }
}
