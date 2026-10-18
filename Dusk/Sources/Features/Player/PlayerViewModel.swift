import Foundation
import OSLog
import SwiftUI

let autoSkipIntroLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "AutoSkipIntro"
)

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
    /// Mirrors `UserPreferences.subtitleFontSize` so the in-player picker can
    /// observe it. Changing it there writes straight back to preferences.
    var subtitleFontSize: SubtitleFontSize = .default
    var showControls = true
    var aspectFillEnabled = false
    var showSubtitlePicker = false
    var showSubtitleSizePicker = false
    var showSubtitleSearch = false
    var showAudioPicker = false
    var showQualityPicker = false
    var showPlaybackInfo = false
    var isControlsInteractionHeld = false
    var isScrubbing = false
    var scrubPosition: TimeInterval = 0
    var seekFeedback: PlayerSeekFeedbackPresentation?
    var autoSkipCountdownProgress: Double?
    var isSpeedBoostActive = false
    /// Viewer-chosen playback speed. Separate from the transient press-and-hold
    /// 2× boost, which overrides it while held and restores it on release.
    /// Reset per session, because the engine is rebuilt with the session.
    var playbackRate: Float = 1
    #if os(tvOS)
    /// tvOS routes every HUD reveal through `PlayerTVHUDController`. Set while
    /// the controller performs an action that must not raise the HUD — a
    /// Skip Intro activation from the hidden state.
    @ObservationIgnored var suppressControlsReveal = false
    #endif

    let engine: any PlaybackEngine
    /// The engine's rendering view. Refreshed from `sync()` when the engine
    /// reports a new `playerViewGeneration` (VLCKit swaps its rendering
    /// surface when entering Picture in Picture support mode mid-session).
    var engineView: AnyView
    @ObservationIgnored var lastPlayerViewGeneration = 0
    let markers: [PlexMarker]
    /// Refreshed by the coordinator as the tuned channel's schedule rolls over,
    /// so the play bar and header follow the actual programming.
    var liveTVContext: PlexLivePlaybackContext?
    /// Wall-clock view of the live session, rebuilt on every `sync()`. Nil for
    /// everything except Live TV, and until the engine reports a position.
    var liveTimeline: LiveTimelineSnapshot?
    @ObservationIgnored var liveEdgeClock = LiveEdgeClock()
    var hasLoadedSource = false
    var sourcePart: PlexMediaPart?
    var preferredSubtitleLanguage: String?
    var preferredAudioLanguage: String?
    var subtitleForcedOnly = false
    var autoSkipIntroMode: AutoSkipIntroMode = .alwaysExceptFirstEpisode
    var autoSkipCountdownMarkerID: Int?
    var autoSkipHandler: (@MainActor (PlexMarker) -> Void)?
    /// Markers this episode has already skipped once, seeded from the
    /// coordinator so the record survives a rebuilt player (quality switch,
    /// Picture in Picture restore). A marker in here never arms another
    /// auto-skip countdown: seeking back into the intro shows the button again,
    /// but the jump forward is the viewer's to make.
    @ObservationIgnored var spentAutoSkipMarkerIDs: Set<Int> = []
    /// Fingerprint decisions completed for this episode. Unlike spent marker
    /// IDs, this also includes first openings that played through.
    @ObservationIgnored var resolvedIntroFingerprintMarkerIDs: Set<Int> = []
    /// Deduplicates the auto-skip eligibility trace emitted by the 250 ms sync
    /// loop; the trace should describe transitions, not flood the device log.
    @ObservationIgnored var lastAutoSkipDiagnosticSnapshot: String?
    /// Reports a newly spent auto-skip back to the coordinator, which owns the
    /// per-episode record.
    var autoSkipSpentHandler: (@MainActor (Int) -> Void)?
    var introFingerprintResolvedHandler: (@MainActor (Int) -> Void)?
    /// Fires when the reached credits marker changes (nil when leaving the
    /// credits, e.g. a seek back before the marker). The player forwards it to
    /// the coordinator, which resolves the next episode and shows/hides the
    /// bottom-right Up Next poster.
    var upNextPosterHandler: (@MainActor (PlexMarker?) -> Void)?
    @ObservationIgnored var lastNotifiedCreditsMarkerID: Int?
    var hasConfiguredAutomaticTrackSelection = false
    var hasAppliedAutomaticAudioSelection = false
    var hasAppliedAutomaticSubtitleSelection = false
    /// Sidecar subtitles mount a beat after the container's own tracks, so the
    /// one-shot automatic choice is re-evaluated exactly once after an external
    /// track appears — and never after the viewer has chosen for themselves.
    var hasReappliedAutomaticSubtitleSelectionForExternalTracks = false
    var hasUserSelectedSubtitleTrack = false
    /// Builds the token-bearing URL for a Plex sidecar subtitle stream. Set by
    /// `PlayerView` from the coordinator's `PlexService`; nil in previews, where
    /// external streams then simply stay out of the picker.
    @ObservationIgnored var externalSubtitleURLProvider: (@MainActor (PlexStream) -> URL?)?
    /// Asks the coordinator to restart this session on VLCKit so a Plex sidecar
    /// can be mounted. Fired when the viewer picks an external subtitle in an
    /// AVPlayer session, which cannot attach one to a live item.
    var externalSubtitleRestartHandler: (@MainActor (Int) -> Void)?
    /// Plex subtitle stream id to select as soon as it is mounted: carried
    /// across the AVPlayer → VLCKit restart and set after a subtitle download.
    var pendingExternalSubtitleStreamID: Int?
    /// External Plex streams already handed to the engine this session.
    @ObservationIgnored var attachedExternalSubtitleStreamIDs: Set<Int> = []
    /// The part's sidecar subtitle streams paired with their resolved URLs.
    /// Cached because the track lists are rebuilt on every sync tick and
    /// building a stream URL is not free.
    @ObservationIgnored var externalSubtitleStreams: [(stream: PlexStream, url: URL)] = []
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
    /// AirPlay track pickers represent original Plex streams even though the
    /// AVPlayer HLS item contains only the server-rendered selection. Changes
    /// therefore rebuild the Plex stream instead of selecting an engine track.
    var usesServerTrackSelection = false
    /// A Dolby Atmos remux delivers the server-selected text subtitle as an
    /// HLS subtitle rendition the local engine still has to switch on.
    @ObservationIgnored var pendingServerSubtitleRenditionSelection = false
    /// Plex streams the viewer explicitly chose before an engine swap (Atmos
    /// remux → direct play). They replace the automatic picks once.
    @ObservationIgnored var explicitTrackSelection: ExplicitTrackSelection?
    var serverSelectedAudioStreamID: Int?
    var serverSelectedSubtitleStreamID: Int?
    var userTrackSelectionHandler: (@MainActor (PlexStreamType, Int?) -> Void)?
    var plexTrackSelectionHandler: (@MainActor (Int?, Int?) -> Void)?
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
    @ObservationIgnored nonisolated(unsafe) var seekFeedbackTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var autoSkipCountdownTask: Task<Void, Never>?
    @ObservationIgnored private(set) var introFingerprintStore: IntroFingerprintStore
    @ObservationIgnored var introFingerprintSeasonKey: IntroFingerprintSeasonKey?
    @ObservationIgnored var currentEpisodeRatingKey: String?
    @ObservationIgnored var currentMediaType: PlexMediaType?
    @ObservationIgnored var introOpeningSessionState = IntroOpeningSessionState()
    @ObservationIgnored var introFrameSamplingMarkerID: Int?
    @ObservationIgnored var introFrameSamplingGeneration = UUID()
    @ObservationIgnored var lastIntroFrameRequestTime: TimeInterval?
    @ObservationIgnored var lastIntroPlaybackTime: TimeInterval?
    @ObservationIgnored var lastIntroPlaybackWallTime: Date?
    @ObservationIgnored var introFingerprintMatchingTask: Task<Void, Never>?
    @ObservationIgnored var introFingerprintSampleRequestCount = 0
    @ObservationIgnored var introFrameSamplingTask: Task<Void, Never>?
    /// Preferences store used to persist the per-orientation zoom-to-fill
    /// choice. Set from `configureAutomaticTrackSelection` on appear.
    @ObservationIgnored var userPreferences: UserPreferences?
    /// Current player orientation (nil until the first layout pass). Portrait
    /// and landscape each remember their own zoom-to-fill setting.
    @ObservationIgnored var isLandscapeVideoOrientation: Bool?

    init(
        engine: any PlaybackEngine,
        markers: [PlexMarker] = [],
        liveTVContext: PlexLivePlaybackContext? = nil,
        introFingerprintStore: IntroFingerprintStore? = nil
    ) {
        self.engine = engine
        self.introFingerprintStore = introFingerprintStore ?? .shared
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
        introFrameSamplingTask?.cancel()
        introFingerprintMatchingTask?.cancel()
    }

    func cleanup() {
        syncTimer?.invalidate()
        controlsAutoHideTask?.cancel()
        seekFeedbackTask?.cancel()
        cancelAutoSkipCountdown()
        syncTimer = nil
        controlsAutoHideTask = nil
        controlsAutoHideDeadline = nil
        controlsInteractionHoldCount = 0
        isControlsInteractionHeld = false
        seekFeedbackTask = nil
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
        mediaDetails: PlexMediaDetails? = nil,
        usesServerTrackSelection: Bool = false,
        rendersServerSubtitleTrack: Bool = false,
        selectedAudioStreamID: Int? = nil,
        selectedSubtitleStreamID: Int? = nil,
        pendingExternalSubtitleStreamID: Int? = nil,
        explicitTrackSelection: ExplicitTrackSelection? = nil,
        spentAutoSkipMarkerIDs: Set<Int> = [],
        resolvedIntroFingerprintMarkerIDs: Set<Int> = [],
        introOpeningSessionState: IntroOpeningSessionState? = nil,
        viewerProfileID: String? = nil
    ) {
        userPreferences = preferences
        // Apply the saved zoom-to-fill choice now that preferences are known.
        // Safe to call in any order relative to the first layout pass: it
        // no-ops until an orientation is also known.
        applyPersistedAspectFill()
        sourcePart = part
        self.usesServerTrackSelection = usesServerTrackSelection
        serverSelectedAudioStreamID = selectedAudioStreamID
        serverSelectedSubtitleStreamID = selectedSubtitleStreamID
        pendingServerSubtitleRenditionSelection = usesServerTrackSelection
            && rendersServerSubtitleTrack
            && selectedSubtitleStreamID != nil
        self.explicitTrackSelection = usesServerTrackSelection ? nil : explicitTrackSelection
        preferredSubtitleLanguage = Self.normalizedLanguageCode(preferences.defaultSubtitleLanguage)
        preferredAudioLanguage = Self.normalizedLanguageCode(preferences.defaultAudioLanguage)
        subtitleForcedOnly = preferences.subtitleForcedOnly
        subtitleFontSize = preferences.subtitleFontSize
        let nextAutoSkipIntroMode = preferences.autoSkipIntroMode
        let nextMediaType = mediaDetails?.type
        let nextEpisodeRatingKey = mediaDetails?.type == .episode ? mediaDetails?.ratingKey : nil
        let nextFingerprintSeasonKey = mediaDetails.flatMap {
            IntroFingerprintSeasonKey(mediaDetails: $0, viewerProfileID: viewerProfileID)
        }
        let episodeChanged = currentMediaType != nextMediaType
            || currentEpisodeRatingKey != nextEpisodeRatingKey
            || introFingerprintSeasonKey != nextFingerprintSeasonKey
        if episodeChanged {
            cancelAutoSkipCountdown(reason: "configuration-changed")
        } else if autoSkipIntroMode != nextAutoSkipIntroMode {
            cancelAutoSkipCountdown(reason: "saved-mode-changed")
        }
        if episodeChanged {
            self.resolvedIntroFingerprintMarkerIDs = []
        }
        if let introOpeningSessionState {
            self.introOpeningSessionState = introOpeningSessionState
        } else if episodeChanged {
            self.introOpeningSessionState = IntroOpeningSessionState()
        }
        autoSkipIntroMode = nextAutoSkipIntroMode
        currentMediaType = nextMediaType
        currentEpisodeRatingKey = nextEpisodeRatingKey
        introFingerprintSeasonKey = nextFingerprintSeasonKey
        if let key = nextFingerprintSeasonKey {
            introFingerprintStore.registerSeason(key, showRatingKey: mediaDetails?.grandparentRatingKey)
            if self.introOpeningSessionState.fingerprintCacheGeneration == nil {
                self.introOpeningSessionState.fingerprintCacheGeneration = introFingerprintStore.generation(for: key)
            }
        }
        self.spentAutoSkipMarkerIDs = spentAutoSkipMarkerIDs
        if markers.contains(where: { $0.isIntro && spentAutoSkipMarkerIDs.contains($0.id) }) {
            self.introOpeningSessionState.hasSkippedIntro = true
        }
        self.resolvedIntroFingerprintMarkerIDs = resolvedIntroFingerprintMarkerIDs
        lastAutoSkipDiagnosticSnapshot = nil
        let markerSummary = markers.map {
            "\($0.id):\($0.type) \(Double($0.startTimeOffset) / 1_000)-\(Double($0.endTimeOffset) / 1_000)s"
        }.joined(separator: ",")
        let seasonIdentity = nextFingerprintSeasonKey.map {
            "server=\($0.serverID) season=\($0.seasonRatingKey)"
        } ?? "unavailable"
        autoSkipIntroLogger.notice(
            "Configured model=\(ObjectIdentifier(self).debugDescription, privacy: .public) mode=\(nextAutoSkipIntroMode.rawValue, privacy: .public) type=\(String(describing: nextMediaType), privacy: .public) episode=\(nextEpisodeRatingKey ?? "unavailable", privacy: .public) fingerprintScope=\(seasonIdentity, privacy: .public) markers=[\(markerSummary, privacy: .public)] engineState=\(String(describing: self.state), privacy: .public) engineTime=\(self.engine.currentTime, format: .fixed(precision: 3)) buffering=\(self.engine.isBuffering) spent=\(self.spentAutoSkipMarkerIDs.sorted().description, privacy: .public) resolved=\(self.resolvedIntroFingerprintMarkerIDs.sorted().description, privacy: .public)"
        )
        hasConfiguredAutomaticTrackSelection = true
        hasAppliedAutomaticAudioSelection = false
        hasAppliedAutomaticSubtitleSelection = false
        hasReappliedAutomaticSubtitleSelectionForExternalTracks = false
        hasUserSelectedSubtitleTrack = false
        // A Plex sidecar picked before an engine swap (or downloaded mid-item)
        // is selected as soon as the new engine has mounted it.
        self.pendingExternalSubtitleStreamID = pendingExternalSubtitleStreamID
        attachedExternalSubtitleStreamIDs = []
        rebuildExternalSubtitleStreamIndex()
        syncTrackLists()
        applyAutomaticTrackSelectionIfNeeded()
        updateAutoSkipState()
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
