import Foundation
import SwiftUI
#if os(tvOS)
#if canImport(UIKit)
import UIKit
#endif
#endif

enum PlayerLoadingState: Equatable {
    case hidden
    case preparing
    case starting
    case buffering
    case recovering

    var isVisible: Bool {
        self != .hidden
    }
}

/// Orchestrates the "play an item" flow: fetch metadata → resolve engine →
/// construct URL → present player → report timeline → scrobble.
///
/// Injected into the environment so any view can trigger playback via
/// `coordinator.play(id:resumeOffsetMilliseconds:)`. The player is
/// presented as a full-screen cover in MainTabView.
@MainActor @Observable
final class PlaybackCoordinator {
    var showPlayer = false
    var loadError: String?
    /// What we know about the item being loaded (title/poster), shown by the
    /// player cover's loading state until the engine takes over. Nil once a
    /// session commits or the cover is torn down.
    var loadingPlaceholder: PlaybackPlaceholder?
    var engine: (any PlaybackEngine)?
    var debugInfo: PlaybackDebugInfo?
    var playbackSource: PlaybackSource?
    var playerPresentationID = UUID()
    /// The session whose delayed mid-play buffering presentation is active.
    /// The id prevents a departing session from clearing its successor's state.
    private var bufferingPresentationID: UUID?
    var upNextPresentation: UpNextPresentation?
    /// The small bottom-right "next episode" poster shown over the play bar once
    /// the credits marker is reached (replaces the old Skip Credits button). Nil
    /// when not in credits, when there is no next episode, or while the
    /// full-screen `upNextPresentation` is showing instead.
    var upNextPoster: UpNextPosterPresentation?
    /// Up Next During Credits off (#84): what the hidden card would have
    /// advanced to at the natural end (its `timedAutoplay`/`autoAdvanceAtEnd`
    /// modes), so turning the card off keeps that direct advance.
    @ObservationIgnored var hiddenUpNextAdvance: UpNextCandidate?
    /// The server's pre-roll videos while they play ahead of a movie; nil
    /// otherwise. See `PlaybackCoordinator+Prerolls`.
    var prerollPlayback: PrerollPlayback?
    /// Previous / Next Episode targets for the episode now playing; nil for
    /// anything that is not a library episode (movies, clips, Live TV).
    var adjacentEpisodes: PlaybackAdjacentEpisodes?
    /// The playlist being played through, with the position of the item now
    /// playing; nil for ordinary playback, whose Up Next is the show's next
    /// episode. Set by `playQueue`, kept across Up Next and Previous / Next,
    /// dropped by any other Play and when the cover closes.
    var playbackQueue: PlaybackQueue?
    /// Markers whose one-shot auto-skip has been used up for the item currently
    /// playing: an intro Dusk (or the viewer) already skipped, and credits whose
    /// auto-advance countdown already ran or was waved off. Auto-skip is a
    /// once-per-episode courtesy — seeking back into a marker must never jump
    /// the viewer forward again on its own. Owned here rather than in
    /// `PlayerViewModel` so it survives the engine swaps that rebuild the player
    /// (quality switch, delivery-ladder fallback, Picture in Picture restore);
    /// cleared when the next item's session commits.
    @ObservationIgnored var spentAutoSkipMarkerIDs: Set<String> = []
    /// The Dolby Vision 7 → 8.1 conversion failed for the item now playing,
    /// so its remux is rebuilt (and kept) without it. Reset for each new item.
    @ObservationIgnored var isDolbyVision7ConversionSuppressed = false
    /// A remux of the item now playing has actually played, so a later failure
    /// is a dropped session rather than a stream AVPlayer cannot open. Reset
    /// for each new item.
    @ObservationIgnored var didRemuxReachPlayback = false
    /// Fresh remuxes requested for the item now playing after a live HDR remux
    /// failed (`recoverLiveHDRRemux`). Reset for each new item.
    @ObservationIgnored var liveRemuxRecoveryAttempts = 0
    /// Manual audio sync for the item now playing (#67; positive delays the
    /// audio). Per item: reset when the next item's session commits.
    var audioOffsetMilliseconds = 0
    /// The offset moved this item from AVPlayer to VLCKit, so later
    /// replacements of it stay on VLCKit (see `AudioOffsetPolicy`). Reset
    /// with the offset.
    @ObservationIgnored var isAudioOffsetPinnedToVLCKit = false
    /// The offset switch rebuilt the player under the open audio options;
    /// the new player opens them again once its tracks are in.
    @ObservationIgnored var reopensAudioOptionsAfterEngineSwitch = false
    var isSwitchingQuality = false
    var qualitySwitchError: String?
    /// System AirPlay route state shared by playback preparation and the iOS
    /// route-picker UI. The selected route itself remains owned by the system.
    let airPlayController: PlaybackAirPlayController
    /// Group Activities lifecycle and engine coordination for SharePlay.
    let sharePlayController: PlaybackSharePlayController
    /// True while Plex prepares an AVPlayer HLS replacement after the user
    /// selects an AirPlay route during an active local session.
    var isPreparingAirPlay = false
    @ObservationIgnored var showTrackPreferenceStore = ShowTrackPreferenceStore()
    @ObservationIgnored var activeShowTrackScope: ShowTrackPreferenceStore.Scope?
    /// Plex stream selections that must survive local → AirPlay handoffs. Engine
    /// ids are implementation-local, so the player maps them back to these ids.
    var activeAudioStreamID: String?
    /// A picker choice for this item, including movies. Survives player
    /// presentation and engine replacements; cleared when a new item commits.
    var manuallySelectedAudioStreamID: String?
    var activeSubtitleStreamID: String?
    /// Set while a remux session has Plex convert its audio (TrueHD and other
    /// codecs the fMP4 cannot carry). Rebuilding that remux around the same
    /// audio stream must keep converting: the stream itself may be locally
    /// decodable (TrueHD on Dusk's VLCKit), so decodability cannot re-derive it.
    var remuxAudioConversion: RemuxAudioConversion?
    /// Confirmed tracks in the loaded remux / AV1 conversion, retained while
    /// a new selection is prepared so a declined change can keep playing.
    var remuxTrackSelection: ExplicitTrackSelection?
    /// The part's server-side selection from before an automatic remux start
    /// overwrote it, written back when the session ends (see
    /// `noteAutomaticServerSelectionWrite`).
    @ObservationIgnored var automaticServerSelectionRestore: ServerStreamSelectionRestore?
    /// Plex subtitle stream id to select as soon as the player can mount it.
    /// Set by the sidecar-download flow and by the AVPlayer → VLCKit switch,
    /// consumed by `PlayerViewModel.configureAutomaticTrackSelection`.
    var pendingExternalSubtitleStreamID: String?
    /// Plex audio/subtitle choice to carry into the next player configuration
    /// when a remux returns to direct play or enhanced SDR subtitles switch
    /// tvOS from AVPlayer to VLCKit. Consumed once by `PlayerView`.
    var pendingExplicitTrackSelection: ExplicitTrackSelection?
    /// Bumped when `refreshSubtitleStreamsAfterDownload` replaced the active
    /// part snapshot. The player observes it and re-reads the part's subtitle
    /// streams in place, without rebuilding the session.
    var externalSubtitleRefreshToken = UUID()
    /// Digest of the sidecar a subtitle download is about to replace, taken
    /// just before the request (see `prepareSubtitleDownload`). Consumed by
    /// `refreshSubtitleStreamsAfterDownload`.
    @ObservationIgnored var subtitleDownloadBaselineDigest: Data?
    /// True while a direct-play or remux attempt still has automatic recovery
    /// available. Used to keep a transient engine error
    /// hidden until that recovery attempt succeeds or definitively fails.
    var isAutomaticDirectPlayFallbackAvailable = false
    /// True after an attempt fails while its replacement is being prepared.
    /// Drives the continuous loading presentation.
    var isAutomaticDirectPlayFallbackActive = false
    var isAutomaticDirectPlayFallbackPending: Bool {
        isAutomaticDirectPlayFallbackAvailable || isAutomaticDirectPlayFallbackActive
    }
    /// True while a Picture in Picture window is showing. The full-screen player
    /// cover is dropped while this is set, so the engine must outlive the cover's
    /// dismissal (see `onPlayerDismissed`).
    var isPictureInPictureActive = false
    /// Completion handed up by AVKit's restore delegate; fired once the
    /// re-presented player UI reports it is on screen.
    @ObservationIgnored var pendingPictureInPictureRestoreCompletion: ((Bool) -> Void)?
    /// The player scene reached `.background` since it was last active. Only
    /// then does the engine need its post-background render refresh.
    @ObservationIgnored var playerSceneWasBackgrounded = false

    let media: MediaService
    let preferences: UserPreferences
    let downloadManager: DownloadManager?
    let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    /// Set once by `DuskApp`; receives each scrobbled movie/episode.
    @ObservationIgnored var traktService: TraktService?
    @ObservationIgnored let nowPlayingController = PlaybackNowPlayingController()
    var itemID: String?
    /// The server the live session is actually playing from. Authoritative for
    /// timeline, scrobble, transcode ping/stop, subtitles, scrub previews and
    /// Up Next: a rating key means something different on every other server,
    /// so none of it may be fanned out to the pool.
    var activePlaybackServerID: String?
    var activePlaybackUsesLocalDownload = false
    var activeItemDetails: MediaDetails?
    var activeLiveTVContext: LivePlaybackContext?
    /// A past IPTV programme (catch-up) is playing. No live context, so the
    /// player is the ordinary on-demand one, but like a live IPTV channel
    /// nothing of it may reach Plex.
    var isPlayingIPTVCatchUp = false
    /// The catch-up programme playing, for its local resume point
    /// (`IPTVResumeStore`); nil for everything else.
    @ObservationIgnored var activeIPTVResumeKey: IPTVResumeKey?
    @ObservationIgnored var iptvResumeLastSavedAt: Date?
    var hasScrobbled = false
    var didFinalizeCurrentSession = false
    var isHandlingPlaybackEnded = false
    var lastReportedTimeMs = 0
    var lastReportedDurationMs = 0
    var continuousPlayEpisodeRunCount = 0
    var activePlaybackSessionIdentifier: String?
    var activeTranscodeSessionID: String?
    /// Counts 10-second timeline ticks so the transcode keep-alive ping fires
    /// roughly every 60 seconds while a server transcode session is active.
    @ObservationIgnored var transcodePingTickCounter = 0

    /// Identifies the in-flight playback attempt. Set when an attempt begins
    /// (fresh Play or Up Next) and checked after every `await` so a dismissal or
    /// a newer attempt supersedes a slow load instead of committing over it.
    @ObservationIgnored var currentPlaybackAttemptID: UUID?

    /// The first and the latest item a session committed since the player cover
    /// last opened. Survives teardown so the page under the cover can follow a
    /// continuous-play run once it closes (see `advancedEpisodeOnClose`).
    @ObservationIgnored var coverFirstCommittedItem: MediaDetails?
    @ObservationIgnored var coverLastCommittedItem: MediaDetails?
    /// Bumped once the player cover has finished dismissing (its `onDismiss`).
    /// `showPlayer` turns false when the dismissal starts, before tvOS hands
    /// focus back to whatever had it, so a page moving focus must wait for this.
    var playerCoverDismissals = 0

    /// Latest play/pause state reported by the active session, fed from the
    /// player's snapshot handler. The Up Next poster countdown reads it so it
    /// freezes while the user pauses during the credits instead of autoplaying.
    @ObservationIgnored var latestActivePlaybackState: PlaybackState = .idle

    /// Whether the system idle timer (screen saver / auto-lock) should be
    /// suppressed. Owned here rather than in `PlayerSessionView` because that
    /// view is rebuilt (fresh `.id`) on every episode transition: two idle-timer
    /// modifiers would overlap during the swap and the departing one would clear
    /// the flag the arriving one just set, letting the screen saver appear on the
    /// next episode. On tvOS, each playback snapshot also reconciles UIKit's
    /// actual flag because VLCKit writes it independently on state changes.
    var isIdleTimerSuppressed = false

    @ObservationIgnored nonisolated(unsafe) var timelineTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var upNextCountdownTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var upNextPosterCountdownTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var adjacentEpisodesTask: Task<Void, Never>?
    /// Prefetches the next queued item's metadata (queue sessions only).
    @ObservationIgnored nonisolated(unsafe) var queueLookaheadTask: Task<Void, Never>?
    /// How the queue lookahead (and a failed queue start) reads an item's
    /// metadata. A seam for tests; always the item's own server.
    @ObservationIgnored var queueItemLookup: @MainActor (PlaybackQueueItem) async throws -> MediaDetails = { _ in
        throw PlexServiceError.noServerConnected
    }
    /// One-shot per attempt: observes the engine after an online direct-play
    /// start and swaps the session to the server-stream ladder rung when the
    /// engine fails. Cancelled on finalize/clear/engine swap.
    @ObservationIgnored nonisolated(unsafe) var directPlayFallbackWatchTask: Task<Void, Never>?
    /// The last thrown error of the current candidate walk, so its one
    /// `playback_start_failed` report carries a domain and code.
    @ObservationIgnored var lastStartFailureError: (any Error)?
    @ObservationIgnored nonisolated(unsafe) var airPlayTransitionTask: Task<Void, Never>?
    /// Serializes Atmos-remux rebuilds after track changes.
    @ObservationIgnored nonisolated(unsafe) var spatialAudioTransitionTask: Task<Void, Never>?
    /// Keeps the tuned Live TV channel's schedule current for the length of the
    /// session. Cancelled with the session.
    @ObservationIgnored nonisolated(unsafe) var liveTVScheduleRefreshTask: Task<Void, Never>?

    init(
        media: MediaService,
        preferences: UserPreferences = UserPreferences(),
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        self.media = media
        self.preferences = preferences
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
        let airPlayController = PlaybackAirPlayController()
        let sharePlayController = PlaybackSharePlayController()
        self.airPlayController = airPlayController
        self.sharePlayController = sharePlayController
        airPlayController.routeSelectionDidChange = { [weak self] selected in
            self?.airPlayRouteSelectionDidChange(selected)
        }
        nowPlayingController.userInteractionHandler = { [weak self] in
            self?.noteUserInteraction()
        }
        sharePlayController.playbackCoordinator = self
        sharePlayController.startListening()
        queueItemLookup = { [media] item in
            try await media.getMediaDetails(itemID: item.itemID, serverID: item.serverID)
        }
    }

    deinit {
        timelineTimer?.invalidate()
        directPlayFallbackWatchTask?.cancel()
        airPlayTransitionTask?.cancel()
        spatialAudioTransitionTask?.cancel()
        upNextPosterCountdownTask?.cancel()
        adjacentEpisodesTask?.cancel()
        queueLookaheadTask?.cancel()
        liveTVScheduleRefreshTask?.cancel()
    }

    /// Single source of truth for the full-screen player loading presentation.
    /// PlayerView renders exactly one persistent spinner from this state.
    var playerLoadingState: PlayerLoadingState {
        guard showPlayer else { return .hidden }

        guard let engine else {
            return loadError == nil ? .preparing : .hidden
        }

        if isPreparingAirPlay {
            return .recovering
        }

        if isAutomaticDirectPlayFallbackPending,
           engine.state == .error || engine.error != nil {
            return .recovering
        }

        if engine.state == .error || engine.error != nil {
            return .hidden
        }

        if engine.state == .idle || engine.state == .loading {
            return .starting
        }

        if bufferingPresentationID == playerPresentationID {
            return .buffering
        }

        return .hidden
    }

    /// Hands the pending sidecar selection to the player exactly once. It must
    /// not survive into a later re-presentation of the same session (returning
    /// from Picture in Picture), or it would override the viewer's own choice.
    func consumePendingExternalSubtitleStreamID() -> String? {
        defer { pendingExternalSubtitleStreamID = nil }
        return pendingExternalSubtitleStreamID
    }

    /// The current library source was prepared specifically for AirPlay. This
    /// remains true if the route disconnects mid-item because keeping HLS local
    /// avoids a second disruptive engine/source handoff.
    var isAirPlaySession: Bool {
        if case .airPlay? = debugInfo?.decision { return true }
        return false
    }

    var isSharePlayActive: Bool {
        sharePlayController.isActive
    }

    var isSharePlayStarting: Bool {
        sharePlayController.isStarting
    }

    var sharePlayParticipantCount: Int {
        sharePlayController.participantCount
    }

    var sharePlayError: String? {
        sharePlayController.errorMessage
    }

    /// Server-scoped identity of what is playing, for call sites that route by
    /// item rather than by rating key.
    var activeItemID: MediaItemID? {
        guard let itemID else { return nil }
        return MediaItemID(serverID: activePlaybackServerID, itemID: itemID)
    }

    var canSharePlayCurrentPlayback: Bool {
        activeItemDetails != nil && activeLiveTVContext == nil && activePlaybackServerID != nil
    }

    var currentSharePlayActivity: DuskWatchTogetherActivity? {
        guard let details = activeItemDetails,
              activeLiveTVContext == nil,
              let serverIdentifier = activePlaybackServerID else { return nil }
        let placeholder = PlaybackPlaceholder(details: details)
        return DuskWatchTogetherActivity(
            serverIdentifier: serverIdentifier,
            itemID: details.itemID,
            title: placeholder.title,
            subtitle: placeholder.subtitle
        )
    }

    func toggleSharePlay() async {
        await sharePlayController.toggleForCurrentPlayback()
    }

    func dismissSharePlayError() {
        sharePlayController.dismissError()
    }

    func retryPendingSharePlayActivityIfPossible() async {
        await sharePlayController.retryPendingActivityIfPossible()
    }

    /// Drives the phone's remote presentation. Route selection becomes true
    /// before AVPlayer finishes the handoff; AVPlayer's state covers the brief
    /// period where the system route is active but the audio-session snapshot
    /// has not refreshed yet.
    var isAirPlayPlaybackActive: Bool {
        airPlayController.isAirPlayRouteSelected || engine?.isExternalPlaybackActive == true
    }

    func setBufferingPresentationVisible(
        _ isVisible: Bool,
        for presentationID: UUID
    ) {
        guard presentationID == playerPresentationID else { return }

        let newValue = isVisible ? presentationID : nil
        if bufferingPresentationID != newValue {
            bufferingPresentationID = newValue
        }
    }

    // MARK: - Play an Item

    /// Full "play an item" flow. The player cover is presented immediately on a
    /// loading placeholder, then a server is chosen → metadata fetched → engine
    /// picked → URL built → session committed under the already-visible cover.
    /// `placeholder` is what the caller already knows (title/poster) so the
    /// loading screen isn't blank.
    ///
    /// `id` carries the server the caller was looking at. That server is the
    /// first choice; the same content on other connected servers is used as
    /// fallback (see `PlaybackSourceResolver`).
    /// `resumeOffsetDurationMilliseconds` is the runtime of the copy the offset
    /// was read from. A fallback server only inherits the position when its own
    /// copy is the same length (see `runPlaybackAttempt`), so callers that know
    /// the item's duration should pass it.
    func play(
        id: MediaItemID,
        resumeOffsetMilliseconds: Int?,
        resumeOffsetDurationMilliseconds: Int? = nil,
        placeholder: PlaybackPlaceholder? = nil,
        queue: PlaybackQueue? = nil
    ) async {
        await beginPlayback(
            id: id,
            startPositionOverride: nil,
            resumeOffsetMilliseconds: resumeOffsetMilliseconds,
            resumeOffsetDurationMilliseconds: resumeOffsetDurationMilliseconds,
            selectedMediaID: nil,
            placeholder: placeholder,
            queue: queue
        )
    }

    /// Plays through a queue (a playlist) from its current item. Up Next then
    /// follows the queue instead of the show's next episode, and the queue's
    /// end ends playback. `fromStart` ignores the item's resume offset
    /// (Shuffle, Play from Beginning); otherwise it resumes where it was left,
    /// and a finished item starts over (`queueResumeFallbackOffset`).
    func playQueue(_ queue: PlaybackQueue, fromStart: Bool = false) async {
        guard let item = queue.current else { return }
        await beginPlayback(
            id: item.id,
            startPositionOverride: fromStart ? 0 : nil,
            resumeOffsetMilliseconds: fromStart ? nil : item.queueResumeFallbackOffset,
            resumeOffsetDurationMilliseconds: item.duration,
            selectedMediaID: nil,
            placeholder: PlaybackPlaceholder(queueItem: item),
            queue: queue
        )
    }

    func playLiveTV(
        channel: LiveChannel,
        program: LiveProgram?,
        lineup: LiveTVLineup,
        allowsDirectPlay: Bool = true
    ) async {
        if let stream = channel.iptv {
            await playIPTV(channel: channel, stream: stream, program: program, lineup: lineup)
            return
        }
        // Independently tuned Plex Live TV sessions have different sliding DVR
        // windows, so they cannot share one stable coordinated media timeline.
        sharePlayController.leave()
        let attemptID = UUID()
        let subtitle = channel.displayTitle
        enterLoadingState(
            placeholder: PlaybackPlaceholder(
                title: program?.primaryDisplayTitle ?? channel.displayTitle,
                subtitle: subtitle,
                posterPath: nil,
                backdropPath: program?.preferredLandscapePath ?? channel.thumb,
                artwork: .liveChannel(logoPath: channel.thumb)
            ),
            attemptID: attemptID
        )

        do {
            let tune = try await media.tuneLiveTV(
                provider: lineup.provider,
                channel: channel,
                allowsDirectPlay: allowsDirectPlay
            )
            guard currentPlaybackAttemptID == attemptID else { return }

            let resolver = StreamResolver.evaluateLiveTV(
                media: tune.media,
                forceAVPlayer: preferences.forceAVPlayer,
                forceVLCKit: preferences.forceVLCKit
            )
            airPlayController.refreshRoute(notify: false)
            let engineType: PlaybackEngineType = airPlayController.isAirPlayRouteSelected
                ? .avPlayer
                : resolver.engine
            let resolverReason = airPlayController.isAirPlayRouteSelected
                ? "AirPlay route selected; Plex Live HLS through AVPlayer"
                : resolver.reason
            let newEngine = PlaybackEngineFactory.makeEngine(type: engineType)
            newEngine.configureVideoEnhancement(.disabled)
            newEngine.applySubtitleFontSize(preferences.subtitleFontSize)
            newEngine.applySubtitleStyle(preferences.subtitleStyle)
            newEngine.onPlaybackEnded = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handlePlaybackEnded()
                }
            }
            newEngine.setPictureInPictureDelegate(self)

            let title = program?.primaryDisplayTitle ?? channel.displayTitle
            let context = PlaybackAttemptContext(
                attemptID: attemptID,
                title: title,
                itemID: program?.itemID ?? tune.sessionID,
                engine: engineType,
                resolverReason: resolverReason,
                mediaID: tune.media.id,
                partID: tune.part.id,
                sanitizedPlaybackURL: media.sanitizedPlaybackURLString(for: tune.playbackURL)
            )
            let liveContext = LivePlaybackContext(
                lineup: lineup,
                channel: channel,
                program: program,
                sessionID: tune.sessionID,
                sessionPath: tune.reportKey
            )

            hasScrobbled = false
            didFinalizeCurrentSession = false
            lastReportedTimeMs = 0
            lastReportedDurationMs = 0
            itemID = program?.itemID ?? tune.sessionID
            // Every follow-up call (timeline, transcode ping/stop) has to reach
            // the server that actually holds the tuner session.
            activePlaybackServerID = tune.serverID
            activePlaybackUsesLocalDownload = false
            activePlaybackSessionIdentifier = tune.playbackSessionIdentifier
            activeTranscodeSessionID = tune.transcodeSessionID
            activeItemDetails = nil
            activeLiveTVContext = liveContext
            resetAudioOffset()
            engine = newEngine
            playbackSource = PlaybackSource(
                url: tune.playbackURL,
                startPosition: nil,
                context: context,
                preferredAudioTrackPosition: nil,
                locality: sourceLocality(for: tune.playbackURL, serverID: tune.serverID),
                liveTVContext: liveContext
            )
            debugInfo = PlaybackDebugInfo(
                title: title,
                engine: engineType,
                decision: .liveTV,
                media: tune.media,
                part: tune.part,
                attemptID: attemptID,
                resolverReason: resolverReason,
                sanitizedPlaybackURL: context.sanitizedPlaybackURL
            )
            playerPresentationID = UUID()
            nowPlayingController.beginLiveSession(
                title: title,
                channelTitle: subtitle,
                artworkPath: program?.preferredLandscapePath ?? channel.thumb,
                serverID: tune.serverID,
                engine: newEngine,
                media: media,
                skipBackwardInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
                skipForwardInterval: preferences.playerDoubleTapForwardInterval.timeInterval
            )
            startTimelineReporting()
            startLiveTVScheduleRefresh()
            if tune.isDirectPlay {
                startLiveDirectPlayFallbackWatch(channel: channel, program: program, lineup: lineup)
            }
        } catch {
            guard currentPlaybackAttemptID == attemptID else { return }
            loadError = error.localizedDescription
        }
    }

    // MARK: - IPTV

    /// A past programme of an IPTV channel with catch-up: the channel's
    /// catch-up URL for the programme's times, played like the channel
    /// (same headers, user agent and FairPlay flow) but as a finite stream —
    /// the normal on-demand player with a seek bar, no live HUD, no retune.
    /// Starts at `startPosition` (a resume point) or the beginning.
    /// Returns false when the programme cannot be played back.
    @discardableResult
    func playIPTVCatchUp(
        channel: LiveChannel,
        program: LiveProgram,
        startPosition: TimeInterval? = nil
    ) async -> Bool {
        guard let live = channel.iptv,
              let start = program.beginsAt, let end = program.endsAt,
              let stream = live.catchUpStream(start: start, end: end) else { return false }
        await playIPTV(
            channel: channel,
            stream: stream,
            program: program,
            lineup: nil,
            startPosition: startPosition
        )
        return true
    }

    /// An IPTV channel: always AVPlayer, never VLCKit and never a Plex
    /// server. The stream URL goes to AVPlayer as is, with the source's
    /// headers and a FairPlay key session (`IPTVAsset`). Shares the Live TV
    /// player (HUD, live seek bar, channel switching, audio tracks, AirPlay);
    /// nothing is reported to Plex, Trakt or the offline sync.
    private func playIPTV(
        channel: LiveChannel,
        stream: IPTVPlayableChannel,
        program: LiveProgram?,
        lineup: LiveTVLineup?,
        startPosition: TimeInterval? = nil
    ) async {
        sharePlayController.leave()
        let attemptID = UUID()
        let isCatchUp = stream.isCatchUp
        let subtitle = isCatchUp ? Self.catchUpSubtitle(channel: channel, program: program) : channel.displayTitle
        let title = program?.primaryDisplayTitle ?? channel.displayTitle
        enterLoadingState(
            placeholder: PlaybackPlaceholder(
                title: title,
                subtitle: subtitle,
                posterPath: nil,
                backdropPath: program?.preferredLandscapePath ?? channel.thumb,
                artwork: .liveChannel(logoPath: channel.thumb),
                serverID: IPTVImages.serverID
            ),
            attemptID: attemptID
        )

        // Widevine, PlayReady and friends cannot play on Apple hardware; say
        // so instead of letting AVPlayer fail on an unreadable playlist.
        if case .unsupported(let keySystem) = stream.drm?.keySystem {
            loadError = FairPlayError.unsupportedKeySystem(keySystem).localizedDescription
            return
        }

        let sessionID = "iptv-\(attemptID.uuidString)"
        let newEngine = PlaybackEngineFactory.makeEngine(type: .avPlayer)
        newEngine.configureVideoEnhancement(.disabled)
        newEngine.applySubtitleFontSize(preferences.subtitleFontSize)
        newEngine.applySubtitleStyle(preferences.subtitleStyle)
        newEngine.onPlaybackEnded = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handlePlaybackEnded()
            }
        }
        newEngine.setPictureInPictureDelegate(self)

        let sanitizedURL = IPTVAsset.sanitizedURLString(stream.streamURL)
        let context = PlaybackAttemptContext(
            attemptID: attemptID,
            title: title,
            itemID: sessionID,
            engine: .avPlayer,
            resolverReason: isCatchUp ? "IPTV catch-up; always AVPlayer" : "IPTV channel; always AVPlayer",
            mediaID: "0",
            partID: "0",
            sanitizedPlaybackURL: sanitizedURL
        )
        // A catch-up programme has no live context: it plays in the
        // on-demand player.
        let liveContext = lineup.flatMap { lineup in
            isCatchUp ? nil : LivePlaybackContext(
                lineup: lineup,
                channel: channel,
                program: program,
                sessionID: sessionID,
                sessionPath: nil
            )
        }

        hasScrobbled = false
        didFinalizeCurrentSession = false
        lastReportedTimeMs = 0
        lastReportedDurationMs = 0
        // Only keys the session locally (Now Playing, timeline ticks);
        // `reportTimelineOrQueueOfflineSync` never sends IPTV to Plex.
        itemID = sessionID
        activePlaybackServerID = nil
        activePlaybackUsesLocalDownload = false
        activePlaybackSessionIdentifier = nil
        activeTranscodeSessionID = nil
        activeItemDetails = nil
        activeLiveTVContext = liveContext
        isPlayingIPTVCatchUp = isCatchUp
        activeIPTVResumeKey = isCatchUp ? program.flatMap { IPTVResumeKey(channel: channel, program: $0) } : nil
        iptvResumeLastSavedAt = nil
        engine = newEngine
        var source = PlaybackSource(
            url: stream.streamURL,
            startPosition: isCatchUp ? startPosition : nil,
            context: context,
            preferredAudioTrackPosition: nil,
            locality: .remoteNetwork,
            liveTVContext: liveContext
        )
        source.iptvStream = stream
        if isCatchUp, let program {
            source.iptvCatchUp = IPTVCatchUpPlayback(program: program, subtitle: subtitle)
        }
        playbackSource = source
        // No Plex media to describe; the debug overlay stays off.
        debugInfo = nil
        playerPresentationID = UUID()
        nowPlayingController.beginLiveSession(
            title: title,
            channelTitle: subtitle,
            artworkPath: program?.preferredLandscapePath ?? channel.thumb,
            serverID: IPTVImages.serverID,
            engine: newEngine,
            media: media,
            skipBackwardInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
            skipForwardInterval: preferences.playerDoubleTapForwardInterval.timeInterval,
            isLive: !isCatchUp
        )
        startTimelineReporting()
        if liveContext != nil {
            startLiveTVScheduleRefresh()
        }
    }

    /// "Channel · Tue 18:00": which airing a catch-up session is.
    private static func catchUpSubtitle(channel: LiveChannel, program: LiveProgram?) -> String {
        guard let beginsAt = program?.beginsAt else { return channel.displayTitle }
        let day = Calendar.current.isDateInToday(beginsAt)
            ? ""
            : beginsAt.formatted(.dateTime.weekday(.abbreviated)) + " "
        return "\(channel.displayTitle) · \(day)\(beginsAt.formatted(date: .omitted, time: .shortened))"
    }

    /// Whether the session is an IPTV channel (its error offers Retry).
    var isPlayingIPTV: Bool {
        activeLiveTVContext?.isIPTV == true
    }

    /// Retry from the player's error: tunes the same IPTV channel again from
    /// scratch, with whatever is on now.
    func retryActiveIPTVChannel() async {
        guard let context = activeLiveTVContext, context.isIPTV else { return }
        await playLiveTV(channel: context.channel, program: context.program(at: .now), lineup: context.lineup)
    }

    // MARK: - Live TV Schedule

    /// Keeps the tuned channel's schedule current for the whole session. The
    /// lineup handed to `playLiveTV` is a snapshot — the home shelf carries
    /// only what was airing when it loaded — so without this the play bar and
    /// the header would still be describing a finished program an hour later.
    private func startLiveTVScheduleRefresh() {
        liveTVScheduleRefreshTask?.cancel()
        guard let sessionID = activeLiveTVContext?.sessionID else { return }

        liveTVScheduleRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeLiveTVContext?.sessionID == sessionID else { return }
                await self.refreshLiveTVSchedule()
                guard !Task.isCancelled,
                      self.activeLiveTVContext?.sessionID == sessionID else { return }
                try? await Task.sleep(for: .seconds(self.liveTVScheduleRefreshDelay))
            }
        }
    }

    func cancelLiveTVScheduleRefresh() {
        liveTVScheduleRefreshTask?.cancel()
        liveTVScheduleRefreshTask = nil
    }

    /// Wakes up just after the current program ends so the switchover is
    /// prompt, and is bounded so a missing or stale schedule still re-checks on
    /// its own.
    private var liveTVScheduleRefreshDelay: TimeInterval {
        let programEnd = activeLiveTVContext?.program(at: .now)?.endsAt
        let delay = programEnd.map { $0.timeIntervalSinceNow + 5 } ?? 0
        return min(max(delay, 60), 15 * 60)
    }

    /// Re-derives the airing program, fetching a fresh grid only once the
    /// schedule Dusk already holds stops covering the near future.
    private func refreshLiveTVSchedule() async {
        guard let context = activeLiveTVContext else { return }

        var programs = context.channelPrograms
        let coverage = programs.compactMap(\.endsAt).max() ?? .distantPast
        // Only a server's lineup is refetched. An IPTV channel's schedule is
        // its source's XMLTV guide, which the lineup already carries for days
        // ahead, and no server serves its source (`MediaService.liveTV(for:)`).
        // The current program is still re-derived below.
        if media.liveTV(for: context.lineup.provider) != nil,
           coverage < Date.now.addingTimeInterval(Self.liveTVScheduleCoverageHorizon) {
            let fetched = await fetchLiveTVSchedule(
                provider: context.lineup.provider,
                channel: context.channel
            )
            guard activeLiveTVContext?.sessionID == context.sessionID else { return }
            if !fetched.isEmpty {
                programs = fetched
            }
        }

        guard !programs.isEmpty else { return }
        let refreshed = context.replacingChannelPrograms(programs)
        guard refreshed != activeLiveTVContext else { return }
        activeLiveTVContext = refreshed

        if let title = refreshed.program(at: .now)?.primaryDisplayTitle {
            nowPlayingController.updateLiveProgramTitle(title)
        }
    }

    private func fetchLiveTVSchedule(
        provider: LiveTVProvider,
        channel: LiveChannel
    ) async -> [LiveProgram] {
        var programs = await liveTVGuidePrograms(provider: provider, channel: channel, date: .now)
        // Plex's grid is queried a day at a time, so a session running into the
        // evening outlives today's schedule. Pull tomorrow in as well.
        let coverage = programs.compactMap(\.endsAt).max() ?? .distantPast
        if coverage < Date.now.addingTimeInterval(Self.liveTVScheduleCoverageHorizon),
           let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) {
            programs += await liveTVGuidePrograms(
                provider: provider,
                channel: channel,
                date: tomorrow
            )
        }
        return programs.sorted { ($0.beginsAt ?? .distantPast) < ($1.beginsAt ?? .distantPast) }
    }

    private func liveTVGuidePrograms(
        provider: LiveTVProvider,
        channel: LiveChannel,
        date: Date
    ) async -> [LiveProgram] {
        let lineup = try? await media.getLiveTVGuide(
            provider: provider,
            channels: [channel],
            date: date
        )
        return lineup?.guides.first?.programs ?? []
    }

    /// How far ahead the held schedule must reach before Dusk refetches it.
    private static let liveTVScheduleCoverageHorizon: TimeInterval = 60 * 60

    /// - Parameter restrictToItemServer: keeps the session on the item's own
    ///   server (SharePlay: the whole group is watching that server's copy).
    func playFromStart(
        id: MediaItemID,
        restrictToItemServer: Bool = false,
        placeholder: PlaybackPlaceholder? = nil
    ) async {
        await beginPlayback(
            id: id,
            startPositionOverride: 0,
            resumeOffsetMilliseconds: nil,
            selectedMediaID: nil,
            restrictToItemServer: restrictToItemServer,
            placeholder: placeholder
        )
    }

    #if DEBUG
    /// Screenshot mode (`ScreenshotMode`): starts at an exact position instead
    /// of the item's resume point. With `-DuskScreenshotUpNext` it then raises
    /// the full-screen Up Next screen for the following episode.
    func playForScreenshot(id: MediaItemID, startPosition: TimeInterval?) async {
        await beginPlayback(
            id: id,
            startPositionOverride: startPosition,
            resumeOffsetMilliseconds: nil,
            selectedMediaID: nil,
            placeholder: nil
        )
        guard ScreenshotMode.frozenUpNextSeconds != nil,
              let details = activeItemDetails,
              details.type == .episode,
              let next = await nextEpisode(after: details) else { return }
        try? await Task.sleep(for: .seconds(1))
        presentUpNext(for: UpNextCandidate(item: PlaybackQueueItem(episode: next), queueIndex: nil))
    }
    #endif

    /// An explicitly chosen media version stays on the server it was chosen
    /// from: another server's copy of the same title has entirely different
    /// versions, so falling back would silently play something else.
    func playVersion(
        id: MediaItemID,
        mediaID: String,
        resumeOffsetMilliseconds: Int?,
        placeholder: PlaybackPlaceholder? = nil
    ) async {
        await beginPlayback(
            id: id,
            startPositionOverride: nil,
            resumeOffsetMilliseconds: resumeOffsetMilliseconds,
            selectedMediaID: mediaID,
            restrictToItemServer: true,
            placeholder: placeholder
        )
    }

    /// Present the cover on a loading placeholder first, then prepare the session
    /// in the background so pressing Play feels instant.
    private func beginPlayback(
        id: MediaItemID,
        startPositionOverride: TimeInterval?,
        resumeOffsetMilliseconds: Int?,
        resumeOffsetDurationMilliseconds: Int? = nil,
        selectedMediaID: String?,
        restrictToItemServer: Bool = false,
        placeholder: PlaybackPlaceholder?,
        queue: PlaybackQueue? = nil
    ) async {
        let attemptID = UUID()
        enterLoadingState(placeholder: placeholder, attemptID: attemptID)
        // After the reset: a fresh Play outside a queue drops any old one.
        playbackQueue = queue

        let didStart = await runPlaybackAttempt(
            id: id,
            startPositionOverride: startPositionOverride,
            resumeOffsetMilliseconds: resumeOffsetMilliseconds,
            resumeOffsetDurationMilliseconds: resumeOffsetDurationMilliseconds,
            selectedMediaID: selectedMediaID,
            restrictToItemServer: restrictToItemServer,
            prerollFeature: PrerollPlayback.Feature(
                id: id,
                startPositionOverride: startPositionOverride,
                resumeOffsetMilliseconds: resumeOffsetMilliseconds,
                resumeOffsetDurationMilliseconds: resumeOffsetDurationMilliseconds,
                selectedMediaID: selectedMediaID,
                restrictToItemServer: restrictToItemServer
            ),
            attemptID: attemptID
        )

        // A newer attempt or a dismissal superseded this one while it loaded.
        guard currentPlaybackAttemptID == attemptID else { return }

        if didStart {
            resetContinuousPlayEpisodeRunCountForCurrentItem()
        } else {
            // `runPlaybackAttempt` set `loadError`; the cover surfaces it as an
            // alert (see PlayerView) and stays up on the placeholder until the
            // user dismisses it.
            continuousPlayEpisodeRunCount = 0
        }
    }

    /// Opens the player cover on a loading placeholder and marks the start of a
    /// new playback attempt. Any live session (e.g. a Picture in Picture window)
    /// is finalized first so it does not leak, then its engine is dropped so the
    /// loading state shows instead of the outgoing video.
    private func enterLoadingState(placeholder: PlaybackPlaceholder?, attemptID: UUID) {
        if engine != nil {
            finalizeCurrentPlaybackSession(markCompleted: false)
        }

        currentPlaybackAttemptID = attemptID
        if !showPlayer {
            coverFirstCommittedItem = nil
            coverLastCommittedItem = nil
        }
        loadError = nil
        qualitySwitchError = nil
        loadingPlaceholder = placeholder
        cancelUpNextCountdown()
        cancelUpNextPosterCountdown()
        upNextPresentation = nil
        upNextPoster = nil
        hiddenUpNextAdvance = nil
        prerollPlayback = nil
        clearAdjacentEpisodes()
        playbackQueue = nil

        engine?.onPlaybackEnded = nil
        engine?.setPictureInPictureDelegate(nil)
        engine = nil
        playbackSource = nil
        debugInfo = nil
        activeItemDetails = nil
        activeShowTrackScope = nil
        activeAudioStreamID = nil
        activeSubtitleStreamID = nil
        pendingExternalSubtitleStreamID = nil
        pendingExplicitTrackSelection = nil
        cancelLiveTVScheduleRefresh()
        activeLiveTVContext = nil
        isPlayingIPTVCatchUp = false
        itemID = nil
        isPictureInPictureActive = false
        pendingPictureInPictureRestoreCompletion = nil

        playerPresentationID = UUID()
        noteActivePlaybackState(.idle)
        showPlayer = true
    }

    /// The episode the player was on when its cover closed, when Up Next or
    /// Next Episode moved it past the item the cover opened with; nil when it
    /// never left that item. Detail pages read it when `playerCoverDismissals`
    /// moves to put their episode list on it instead of where the run began.
    var advancedEpisodeOnClose: MediaDetails? {
        guard let last = coverLastCommittedItem,
              last.type == .episode,
              let first = coverFirstCommittedItem,
              first.id != last.id else { return nil }
        return last
    }

    /// Dismisses the player cover after a load-error alert. Teardown runs through
    /// the cover's `onDismiss` (`onPlayerDismissed` → `clearPlayerState`).
    func dismissFailedPlayback() {
        showPlayer = false
        noteActivePlaybackState(.idle)
    }

    /// Called when the full-screen player cover is dismissed.
    /// Sends a final "stopped" timeline, scrobbles if needed, and tears down.
    func onPlayerDismissed() {
        // The cover is also dismissed when PiP takes over (so the floating window
        // is unobstructed). In that case keep the session alive — teardown
        // happens when the PiP window itself closes (see the PiP delegate).
        if isPictureInPictureActive {
            return
        }
        sharePlayController.leave()
        cancelUpNextCountdown()
        finalizeCurrentPlaybackSession(markCompleted: false)
        clearPlayerState()
        showPlayer = false
        playerCoverDismissals += 1
    }

    /// Dismiss any loading error so the UI can return to normal.
    func clearError() {
        loadError = nil
    }

    /// Restart the inactivity streak at zero, independent of engine or platform.
    /// Keep the configured threshold and all active countdowns unchanged.
    func noteUserInteraction() {
        continuousPlayEpisodeRunCount = 0
    }

    /// Every item of a queue session counts toward passout protection, not
    /// just episodes: a playlist of movies autoplays the same way.
    func resetContinuousPlayEpisodeRunCountForCurrentItem() {
        let counts = activeItemDetails?.type == .episode || playbackQueue != nil
        continuousPlayEpisodeRunCount = counts ? 1 : 0
    }

    /// Records that a marker's one-shot auto-skip has been used up for the
    /// item now playing. Called by the player when an intro is skipped and by
    /// the credits poster when its auto-advance is armed or dismissed.
    func noteAutoSkipSpent(markerID: String) {
        spentAutoSkipMarkerIDs.insert(markerID)
    }

    /// Records the live play/pause state so the Up Next poster countdown can
    /// freeze while the user pauses during the credits.
    func noteActivePlaybackState(_ state: PlaybackState) {
        latestActivePlaybackState = state
        if state == .paused, engine?.state == .paused {
            saveIPTVResumePoint()
        }

        // The engine's own state: `state` can be the HUD's optimistic one.
        if engine?.state == .playing, isSpatialAudioSession {
            didRemuxReachPlayback = true
        }

        let shouldSuppress: Bool
        #if os(tvOS)
        // A finalized engine stays behind Up Next, and late engine callbacks
        // must not keep that waiting screen awake. Loading alone is not playback.
        shouldSuppress = showPlayer && !didFinalizeCurrentSession &&
            upNextPresentation == nil && state == .playing
        // VLCKit can change UIKit's flag without changing our observed Bool.
        // Reconcile the actual value on every snapshot, not just on transitions.
        if UIApplication.shared.isIdleTimerDisabled != shouldSuppress {
            UIApplication.shared.isIdleTimerDisabled = shouldSuppress
        }
        #else
        switch state {
        case .loading, .playing:
            shouldSuppress = !isAirPlayPlaybackActive
        case .idle, .paused, .stopped, .error:
            shouldSuppress = false
        }
        #endif
        if isIdleTimerSuppressed != shouldSuppress {
            isIdleTimerSuppressed = shouldSuppress
        }
    }

    /// Resolves an incoming server-scoped activity using this participant's
    /// Plex account, then prepares the item before the GroupSession joins.
    func prepareForSharePlay(
        _ activity: DuskWatchTogetherActivity
    ) async -> SharePlayPlaybackPreparation {
        guard !Task.isCancelled else { return .cancelled }
        guard media.isAuthenticated,
              media.homeBootstrapCompleted,
              !media.needsHomeUserSelection else {
            return .waitingForAccount("Sign in to Plex to join this SharePlay activity.")
        }

        // The hosting server is resolved out of this participant's own pool.
        // Joining a SharePlay session must never move the invitee's session
        // onto another server: with every enabled server connected in
        // parallel, either they already have it or they genuinely don't.
        guard media.pool.connection(for: activity.serverIdentifier) != nil else {
            guard !Task.isCancelled else { return .cancelled }
            return .failed("This Plex account doesn’t have access to the server hosting \(activity.title).")
        }

        guard !Task.isCancelled else { return .cancelled }

        if itemID == activity.itemID,
           activePlaybackServerID == activity.serverIdentifier,
           engine != nil {
            return .ready
        }

        // The group is watching one server's copy: the activity names it, and
        // the readiness check below rejects anything else. Falling back to this
        // participant's higher-priority server would only tear the session down.
        await playFromStart(
            id: MediaItemID(
                serverID: activity.serverIdentifier,
                itemID: activity.itemID
            ),
            restrictToItemServer: true,
            placeholder: PlaybackPlaceholder(
                title: activity.title,
                subtitle: activity.subtitle,
                posterPath: nil,
                backdropPath: nil,
                serverID: activity.serverIdentifier
            )
        )

        guard !Task.isCancelled else { return .cancelled }
        guard itemID == activity.itemID,
              activePlaybackServerID == activity.serverIdentifier,
              engine != nil else {
            return .failed(loadError ?? "Couldn’t prepare \(activity.title) for SharePlay.")
        }
        return .ready
    }
}

// MARK: - Picture in Picture

/// Picture in Picture lifecycle handling.
///
/// The full-screen player cover is dropped while PiP is active so the floating
/// window is unobstructed; the engine outlives the cover because
/// `onPlayerDismissed` and `PlayerViewModel.cleanup` both check
/// `isPictureInPictureActive`. Returning to the app re-presents the cover over
/// the still-live engine — `PlayerViewModel.startPlaybackIfNeeded` skips the
/// reload so playback continues from where the window left it.
extension PlaybackCoordinator: PlaybackPictureInPictureDelegate {
    func pictureInPictureActiveDidChange(_ isActive: Bool) {
        isPictureInPictureActive = isActive

        if isActive {
            // Hide the cover so the floating window stands alone. Teardown is
            // suppressed in onPlayerDismissed while this flag is set.
            if showPlayer {
                showPlayer = false
            }
        } else if !showPlayer {
            // PiP closed while the player UI was dismissed and no restore was
            // requested (e.g. AVKit's close button). Finalize the session as if
            // the player had been dismissed normally.
            cancelUpNextCountdown()
            sharePlayController.leave()
            finalizeCurrentPlaybackSession(markCompleted: false)
            clearPlayerState()
        }
    }

    func pictureInPictureRestorePlayerUI(completion: @escaping (Bool) -> Void) {
        guard !showPlayer else {
            completion(true)
            return
        }

        pendingPictureInPictureRestoreCompletion = completion
        showPlayer = true

        // Safety net: if the re-presented player never reports back, release the
        // system's restore handshake anyway so PiP can finish stopping.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            self?.flushPendingPictureInPictureRestoreCompletion()
        }
    }

    /// Called by the player view once it is back on screen so AVKit can animate
    /// the video out of the PiP window and into the player.
    func notePlayerUIDidAppear() {
        flushPendingPictureInPictureRestoreCompletion()
    }

    private func flushPendingPictureInPictureRestoreCompletion() {
        guard let completion = pendingPictureInPictureRestoreCompletion else { return }
        pendingPictureInPictureRestoreCompletion = nil
        completion(true)
    }
}
