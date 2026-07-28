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
    var seekableRange: ClosedRange<TimeInterval>?
    var isBuffering = false
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
    var isSpeedBoostActive = false

    let engine: any PlaybackEngine
    /// The engine's rendering view. Refreshed from `sync()` when the engine
    /// reports a new `playerViewGeneration` (VLCKit swaps its rendering
    /// surface when entering Picture in Picture support mode mid-session).
    var engineView: AnyView
    @ObservationIgnored var lastPlayerViewGeneration = 0
    let markers: [PlexMarker]
    let liveTVContext: PlexLivePlaybackContext?
    var hasLoadedSource = false
    var sourcePart: PlexMediaPart?
    var preferredSubtitleLanguage: String?
    var preferredAudioLanguage: String?
    var subtitleForcedOnly = false
    var autoSkipIntroMode: AutoSkipIntroMode = .alwaysExceptFirstEpisode
    var isFirstEpisodeInSeason = false
    var autoSkipCountdownMarkerID: Int?
    var autoSkipHandler: (@MainActor (PlexMarker) -> Void)?
    /// Fires when the reached credits marker changes (nil when leaving the
    /// credits, e.g. a seek back before the marker). The player forwards it to
    /// the coordinator, which resolves the next episode and shows/hides the
    /// bottom-right Up Next poster.
    var upNextPosterHandler: (@MainActor (PlexMarker?) -> Void)?
    @ObservationIgnored var lastNotifiedCreditsMarkerID: Int?
    var hasConfiguredAutomaticTrackSelection = false
    var hasAppliedAutomaticAudioSelection = false
    var hasAppliedAutomaticSubtitleSelection = false
    /// One-shot guard for the undecodable-audio transcode fallback. Not reset
    /// by `configureAutomaticTrackSelection` so a re-presented player (e.g.
    /// returning from PiP) cannot restart the session a second time.
    var hasRequestedUndecodableAudioFallback = false
    /// Asks the coordinator to restart playback as a server transcode pinned
    /// to the given audio stream (nil = the part's default audio stream).
    /// Fired when the user picks a track the engine cannot decode locally, or
    /// when a file has no locally decodable audio at all — sound must come
    /// from the server transcoder instead of a dead local decoder.
    var transcodeAudioFallbackHandler: (@MainActor (AudioTrack?) -> Void)?
    var pendingPlaybackState: PlaybackState?
    var pendingPlaybackStateExpiration: Date?
    var playbackSnapshotHandler: (@MainActor (PlaybackState, TimeInterval, TimeInterval) -> Void)?
    /// Reports only the debounced mid-play buffering signal. PlaybackCoordinator
    /// combines it with startup/fallback into the single player loading state.
    var bufferingPresentationHandler: (@MainActor (Bool) -> Void)?
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
    /// Preferences store used to persist the per-orientation zoom-to-fill
    /// choice. Set from `configureAutomaticTrackSelection` on appear.
    @ObservationIgnored var userPreferences: UserPreferences?
    /// Current player orientation (nil until the first layout pass). Portrait
    /// and landscape each remember their own zoom-to-fill setting.
    @ObservationIgnored var isLandscapeVideoOrientation: Bool?

    init(
        engine: any PlaybackEngine,
        markers: [PlexMarker] = [],
        liveTVContext: PlexLivePlaybackContext? = nil
    ) {
        self.engine = engine
        self.engineView = engine.makePlayerView()
        self.lastPlayerViewGeneration = engine.playerViewGeneration
        self.markers = markers.sorted { $0.startTimeOffset < $1.startTimeOffset }
        self.liveTVContext = liveTVContext
        startSync()
    }

    deinit {
        syncTimer?.invalidate()
        controlsAutoHideTask?.cancel()
        seekFeedbackTask?.cancel()
        autoSkipCountdownTask?.cancel()
    }

    func cleanup() {
        syncTimer?.invalidate()
        controlsAutoHideTask?.cancel()
        seekFeedbackTask?.cancel()
        autoSkipCountdownTask?.cancel()
        syncTimer = nil
        controlsAutoHideTask = nil
        controlsAutoHideDeadline = nil
        controlsInteractionHoldCount = 0
        isControlsInteractionHeld = false
        suppressSeekPointSelectUntil = nil
        seekFeedbackTask = nil
        autoSkipCountdownTask = nil
        showQualityPicker = false
        bufferingPresentationHandler?(false)
        bufferingStartedAt = nil
        stalledPlaybackStartedAt = nil
        endSpeedBoost()
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
        userPreferences = preferences
        // Apply the saved zoom-to-fill choice now that preferences are known.
        // Safe to call in any order relative to the first layout pass: it
        // no-ops until an orientation is also known.
        applyPersistedAspectFill()
        sourcePart = part
        preferredSubtitleLanguage = Self.normalizedLanguageCode(preferences.defaultSubtitleLanguage)
        preferredAudioLanguage = Self.normalizedLanguageCode(preferences.defaultAudioLanguage)
        subtitleForcedOnly = preferences.subtitleForcedOnly
        autoSkipIntroMode = preferences.autoSkipIntroMode
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
