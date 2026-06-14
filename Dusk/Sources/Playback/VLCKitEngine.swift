#if canImport(VLCKit)
import CoreVideo
import OSLog
import SwiftUI
import UIKit
import VLCKit
#if os(iOS) || os(tvOS)
import AVFoundation
#endif
#endif

#if canImport(VLCKit)
private let vlcKitEngineLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "VLCKitEngine"
)

/// Platform renderer contract for the shared VLCKit playback core.
protocol VLCKitRenderingHost: AnyObject, Sendable {
    var playerView: UIView { get }

    func attach(to player: VLCMediaPlayer, engine: VLCKitEngine)
    func detach(from player: VLCMediaPlayer)
    func updatePlaybackState(
        currentTimeMs: Int64,
        durationMs: Int64,
        isPlaying: Bool,
        isSeekable: Bool
    )
    func invalidatePlaybackState()
}

@MainActor
private func makeVLCKitRenderingHost() -> any VLCKitRenderingHost {
    #if os(iOS)
    IOSVLCKitRenderingHost()
    #elseif os(tvOS)
    TVOSVLCKitRenderingHost()
    #else
    fatalError("VLCKit is not supported on this platform")
    #endif
}

private final class VLCKitVideoEnhancementFrameSink: NSObject, DuskVLCVideoFrameConsumer, @unchecked Sendable {
    nonisolated(unsafe) private weak var renderer: VideoEnhancementRenderer?

    init(renderer: VideoEnhancementRenderer) {
        self.renderer = renderer
        super.init()
    }

    nonisolated func duskVLCVideoOutputDidProduce(_ pixelBuffer: CVPixelBuffer) {
        guard let renderer else { return }
        let frame = VideoEnhancementFrame(
            retaining: pixelBuffer,
            channelLayout: .rgbaBytesInBGRA
        )
        // Coalesce on the renderer instead of queueing a main-actor task per
        // frame: under GPU load this drops stale frames rather than letting an
        // unbounded backlog push the video into slow motion behind the audio.
        renderer.enqueue(frame: frame)
    }
}

/// PlaybackEngine implementation backed by upstream VLCKit 4.x.
///
/// Shared playback logic lives here. Platform-specific rendering behavior
/// lives in `VLCKitRendererIOS.swift` and `VLCKitRendererTVOS.swift`.
@MainActor
@Observable
final class VLCKitEngine: NSObject, PlaybackEngine {
    private static let seekSettleDelay: Duration = .milliseconds(150)
    private static let seekRetryDelay: Duration = .milliseconds(450)
    private static let pendingSeekTolerance: TimeInterval = 1.0
    private static let pendingSeekStaleUpdateWindow: TimeInterval = 1.5

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isBuffering = false
    private(set) var error: PlaybackError?
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var availableAudioTracks: [AudioTrack] = []
    private(set) var selectedSubtitleTrackID: Int?
    private(set) var selectedAudioTrackID: Int?
    private(set) var playbackDiagnostics: [PlaybackEngineDiagnostic] = []
    var videoEnhancementStatus: VideoEnhancementStatus {
        if let videoEnhancementRenderer {
            return videoEnhancementRenderer.status
        }
        return videoEnhancementRequest.isPotentiallyEnabled
            ? VideoEnhancementStatus(
                state: .unavailable,
                reason: videoEnhancementRequest.preflightUnavailabilityReason ?? "Metal unavailable"
            )
            : .disabled
    }
    var onPlaybackEnded: (@MainActor () -> Void)?

    nonisolated(unsafe) private let mediaPlayer: VLCMediaPlayer
    private let renderingHost: any VLCKitRenderingHost

    private var pendingStartPosition: TimeInterval?
    private var hasAppliedStartPosition = false
    private var hasReportedPlaybackEnded = false
    private var suppressPlaybackEndedEvent = false
    private var ignoreNextStoppedEvent = false
    private var pendingSeekTarget: TimeInterval?
    private var pendingSeekStartedAt: Date?
    private var currentAttemptContext: PlaybackAttemptContext?
    private var currentSource: PlaybackSource?
    private var lastAppliedAudioMixMode: VLCMediaPlayer.AudioMixMode = .modeUnset
    @ObservationIgnored nonisolated(unsafe) private var audioSessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) private var seekVerificationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var loadValidationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var videoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsVideoRefreshOnPlay = false
    @ObservationIgnored private var videoEnhancementRequest: VideoEnhancementRequest = .disabled
    @ObservationIgnored private var videoEnhancementRenderer: VideoEnhancementRenderer?
    @ObservationIgnored nonisolated(unsafe) private var rawVideoFrameSink: VLCKitVideoEnhancementFrameSink?
    @ObservationIgnored nonisolated(unsafe) private var rawVideoOutput: DuskVLCRawVideoOutput?

    override init() {
        let player = VLCMediaPlayer()
        let renderingHost = makeVLCKitRenderingHost()
        self.mediaPlayer = player
        self.renderingHost = renderingHost
        super.init()

        player.delegate = self
        player.timeChangeUpdateInterval = 0.25
        player.minimalTimePeriod = 250_000
        renderingHost.attach(to: player, engine: self)
        configureAudioOutputPolicy()
        registerAudioSessionObserversIfNeeded()
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        loadValidationTask?.cancel()
        seekVerificationTask?.cancel()
        videoRefreshTask?.cancel()
        mediaPlayer.stop()
        rawVideoOutput?.detach()
        mediaPlayer.delegate = nil
        renderingHost.detach(from: mediaPlayer)
    }

    func load(source: PlaybackSource) {
        loadValidationTask?.cancel()
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        rawVideoOutput?.detach()
        currentAttemptContext = source.context
        currentSource = source
        state = .loading
        isBuffering = true
        error = nil
        currentTime = 0
        duration = 0
        hasAppliedStartPosition = false
        hasReportedPlaybackEnded = false
        suppressPlaybackEndedEvent = false
        ignoreNextStoppedEvent = false
        clearPendingSeek()
        pendingStartPosition = source.startPosition
        availableSubtitleTracks = []
        availableAudioTracks = []
        selectedSubtitleTrackID = nil
        selectedAudioTrackID = nil
        playbackDiagnostics = []
        lastAppliedAudioMixMode = .modeUnset
        syncRendererPlaybackState()

        vlcKitEngineLogger.notice(
            "Playback attempt \(source.context.attemptLabel, privacy: .public) starting in VLCKit for ratingKey \(source.context.ratingKey, privacy: .public), media \(source.context.mediaID, privacy: .public), part \(source.context.partID, privacy: .public), URL \(source.context.sanitizedPlaybackURL, privacy: .public)"
        )

        let attemptID = source.context.attemptID
        loadValidationTask = Task { [weak self] in
            guard let self else { return }

            if let validationError = await PlaybackError.validateDirectPlayURL(source.url) {
                guard !Task.isCancelled else { return }
                self.failLoad(
                    validationError,
                    attemptID: attemptID,
                    message: "VLCKit direct-play validation failed"
                )
                return
            }

            guard !Task.isCancelled else { return }
            self.finishValidatedLoad(source: source, attemptID: attemptID)
        }
    }

    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {
        videoEnhancementRequest = request
        videoEnhancementRenderer = VideoEnhancementRenderer(request: request)

        if let videoEnhancementRenderer {
            renderingHost.detach(from: mediaPlayer)
            let frameSink = VLCKitVideoEnhancementFrameSink(renderer: videoEnhancementRenderer)
            rawVideoFrameSink = frameSink
            rawVideoOutput = DuskVLCRawVideoOutput(frameConsumer: frameSink)
        } else {
            rawVideoOutput?.detach()
            rawVideoOutput = nil
            rawVideoFrameSink = nil
            renderingHost.attach(to: mediaPlayer, engine: self)
        }
    }

    func play() {
        let wasPaused = state == .paused
        suppressPlaybackEndedEvent = false
        mediaPlayer.play()
        if wasPaused || needsVideoRefreshOnPlay {
            if needsVideoRefreshOnPlay {
                needsVideoRefreshOnPlay = false
                refreshVideoOutputAfterResume()
            }
            scheduleVideoOutputRefreshAfterResume()
        }
        syncRendererPlaybackState()
    }

    func pause() {
        seekVerificationTask?.cancel()
        seekVerificationTask = nil
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        mediaPlayer.pause()
        state = .paused
        syncRendererPlaybackState()
    }

    func stop() {
        loadValidationTask?.cancel()
        loadValidationTask = nil
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        clearPendingSeek()
        suppressPlaybackEndedEvent = true
        ignoreNextStoppedEvent = false
        mediaPlayer.stop()
        rawVideoOutput?.detach()
        videoEnhancementRenderer?.clear()
        state = .stopped
        hasReportedPlaybackEnded = false
        playbackDiagnostics = []
        currentAttemptContext = nil
        currentSource = nil
        syncRendererPlaybackState()
    }

    func handleReturnToForeground() {
        #if os(iOS)
        // VLCKit ignores track re-selection while paused, so defer the
        // video output refresh until play() is called.
        needsVideoRefreshOnPlay = true
        #endif
    }

    func seek(to position: TimeInterval) {
        let clampedPosition: TimeInterval
        if duration > 0 {
            clampedPosition = min(max(position, 0), duration)
        } else {
            clampedPosition = max(position, 0)
        }

        pendingSeekTarget = clampedPosition
        pendingSeekStartedAt = Date()
        currentTime = clampedPosition

        // Seek without pausing — pausing first creates a race between
        // VLCKit's asynchronous state callbacks and the timed resume,
        // which can leave the player stuck in a paused state.
        applySeek(to: clampedPosition)
        scheduleSeekVerification(target: clampedPosition)
        syncRendererPlaybackState()
    }

    func recoverFromStall() {
        guard let source = currentSource else {
            mediaPlayer.play()
            return
        }

        let recoveryPosition = recoveryStartPosition(for: source)
        if let currentAttemptContext {
            vlcKitEngineLogger.notice(
                "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) VLCKit recovering stalled playback at \(recoveryPosition, privacy: .public)s"
            )
        }

        loadValidationTask?.cancel()
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        clearPendingSeek()
        suppressPlaybackEndedEvent = true
        ignoreNextStoppedEvent = true
        mediaPlayer.stop()
        rawVideoOutput?.detach()
        suppressPlaybackEndedEvent = false

        error = nil
        state = .loading
        isBuffering = true
        pendingStartPosition = recoveryPosition
        hasAppliedStartPosition = recoveryPosition <= 0
        hasReportedPlaybackEnded = false
        availableSubtitleTracks = []
        availableAudioTracks = []
        selectedSubtitleTrackID = nil
        selectedAudioTrackID = nil
        playbackDiagnostics = []
        syncRendererPlaybackState()

        finishValidatedLoad(source: source, attemptID: source.context.attemptID)
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) {
        guard let track else {
            mediaPlayer.deselectAllTextTracks()
            selectedSubtitleTrackID = nil
            return
        }

        mediaPlayer.textTracks
            .first { Int($0.identifier) == track.id }?
            .isSelectedExclusively = true
        selectedSubtitleTrackID = track.id
    }

    func selectAudioTrack(_ track: AudioTrack) {
        mediaPlayer.audioTracks
            .first { Int($0.identifier) == track.id }?
            .isSelectedExclusively = true
        selectedAudioTrackID = track.id
        configureAudioOutputPolicy(reason: "audio-track-selected")
    }

    func makePlayerView() -> AnyView {
        if let videoEnhancementRenderer {
            return AnyView(VideoEnhancementRepresentable(renderer: videoEnhancementRenderer))
        }
        return AnyView(VLCPlayerRepresentable(playerView: renderingHost.playerView))
    }

    fileprivate func handleStateChange(_ vlcState: VLCMediaPlayerState) {
        logStateChange(vlcState)
        switch vlcState {
        case .opening, .buffering:
            isBuffering = true
            if state != .playing && state != .paused {
                state = .loading
            }

        case .playing:
            isBuffering = false
            state = .playing
            suppressPlaybackEndedEvent = false
            configureAudioOutputPolicy(reason: "entered-playing-state")

            if !hasAppliedStartPosition, let start = pendingStartPosition, start > 0 {
                hasAppliedStartPosition = true
                seek(to: start)
            }

            refreshTracks()

        case .paused:
            isBuffering = false
            state = .paused

        case .stopping:
            isBuffering = false

        case .stopped:
            if ignoreNextStoppedEvent {
                ignoreNextStoppedEvent = false
                break
            }

            isBuffering = false
            state = .stopped
            clearPendingSeek()

            if !suppressPlaybackEndedEvent, shouldTreatCurrentStopAsPlaybackEnded {
                currentTime = max(currentTime, duration)
                if !hasReportedPlaybackEnded {
                    hasReportedPlaybackEnded = true
                    if let currentAttemptContext {
                        vlcKitEngineLogger.notice(
                            "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) VLCKit reached end of playback"
                        )
                    }
                    onPlaybackEnded?()
                }
            }

            suppressPlaybackEndedEvent = false

        case .error:
            isBuffering = false
            state = .error
            let parsedStatus = String(describing: mediaPlayer.media?.parsedStatus)
            let attemptLabel = currentAttemptContext?.attemptLabel ?? "unknown"
            let urlLabel = currentAttemptContext?.sanitizedPlaybackURL ?? "<unknown>"
            let libraryError = VLCLibrary.currentErrorMessage
            vlcKitEngineLogger.error(
                "Playback attempt \(attemptLabel, privacy: .public) VLCKit entered error state. parsedStatus=\(parsedStatus, privacy: .public) currentTime=\(self.currentTime, privacy: .public) duration=\(self.duration, privacy: .public) URL=\(urlLabel, privacy: .public) libraryError=\(libraryError ?? "<none>", privacy: .public)"
            )
            error = PlaybackError.fromDirectPlayFailureMessage(
                libraryError ?? vlcPlaybackErrorMessage(),
                fallback: vlcPlaybackErrorMessage()
            )
            clearPendingSeek()
            loadValidationTask = nil

        @unknown default:
            break
        }

        syncRendererPlaybackState()
        renderingHost.invalidatePlaybackState()
    }

    fileprivate func updateTime(timeMs: Int32, lengthMs: Int32) {
        let updatedTime = max(0, TimeInterval(timeMs) / 1000.0)
        if lengthMs > 0 {
            duration = TimeInterval(lengthMs) / 1000.0
        }

        if shouldAcceptUpdatedTime(updatedTime) {
            currentTime = updatedTime
        }
        syncRendererPlaybackState()
    }

    private var shouldTreatCurrentStopAsPlaybackEnded: Bool {
        let durationTolerance = max(1.0, min(5.0, duration * 0.01))
        let reachedDuration = duration > 0 && currentTime >= max(0, duration - durationTolerance)
        let reachedEndPosition = mediaPlayer.position >= 0.98
        return reachedDuration || reachedEndPosition
    }

    private func syncRendererPlaybackState() {
        renderingHost.updatePlaybackState(
            currentTimeMs: Int64(currentTime * 1000),
            durationMs: Int64(duration * 1000),
            isPlaying: state == .playing,
            isSeekable: duration > 0
        )
    }

    private func applySubtitleStyling(to media: VLCMedia) {
        media.addOption(":freetype-color=#FFFFFF")
        media.addOption(":freetype-background-color=#000000")
        media.addOption(":freetype-background-opacity=110")
        media.addOption(":freetype-shadow-color=#000000")
        media.addOption(":freetype-shadow-opacity=80")
        media.addOption(":freetype-shadow-distance=1")
    }

    private func applyNetworkBufferingOptions(to media: VLCMedia) {
        media.addOption(":network-caching=\(PlaybackBufferPolicy.vlcNetworkCachingMilliseconds)")
        media.addOption(":file-caching=\(PlaybackBufferPolicy.vlcFileCachingMilliseconds)")
        media.addOption(":http-reconnect")
    }

    private func applySeek(to position: TimeInterval) {
        if duration > 0 {
            let normalizedPosition = min(max(position / duration, 0), 1)
            if normalizedPosition.isFinite {
                mediaPlayer.position = normalizedPosition
            }
        }

        let targetMs = Int(position * 1000.0)
        mediaPlayer.time = VLCTime(int: Int32(clamping: targetMs))
    }

    private func scheduleSeekVerification(target: TimeInterval) {
        seekVerificationTask?.cancel()
        seekVerificationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.seekSettleDelay)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }

            if self.shouldRetrySeek(toward: target) {
                self.applySeek(to: target)
            }

            do {
                try await Task.sleep(for: Self.seekRetryDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            if self.shouldRetrySeek(toward: target) {
                self.applySeek(to: target)
            }
        }
    }

    private func shouldRetrySeek(toward target: TimeInterval) -> Bool {
        guard let pendingSeekTarget else { return false }
        guard abs(pendingSeekTarget - target) <= Self.pendingSeekTolerance else { return false }
        return !hasReachedPendingSeekTarget(using: observedPlayerTime)
    }

    private func shouldAcceptUpdatedTime(_ updatedTime: TimeInterval) -> Bool {
        guard pendingSeekTarget != nil else { return true }

        if hasReachedPendingSeekTarget(using: updatedTime) {
            clearPendingSeek()
            return true
        }

        let elapsed = pendingSeekStartedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if elapsed < Self.pendingSeekStaleUpdateWindow {
            return false
        }

        clearPendingSeek()
        return true
    }

    private func hasReachedPendingSeekTarget(using updatedTime: TimeInterval) -> Bool {
        guard let pendingSeekTarget else { return true }
        return abs(updatedTime - pendingSeekTarget) <= Self.pendingSeekTolerance
    }

    private var observedPlayerTime: TimeInterval {
        max(0, TimeInterval(mediaPlayer.time.intValue) / 1000.0)
    }

    private func clearPendingSeek() {
        pendingSeekTarget = nil
        pendingSeekStartedAt = nil
        seekVerificationTask?.cancel()
        seekVerificationTask = nil
    }

    private func vlcPlaybackErrorMessage() -> String {
        "Playback failed while opening the direct-play stream."
    }

    private func scheduleVideoOutputRefreshAfterResume() {
        #if os(iOS)
        videoRefreshTask?.cancel()
        videoRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }

            guard let self, self.state == .playing || self.mediaPlayer.isPlaying else { return }
            self.refreshVideoOutputAfterResume()
        }
        #endif
    }

    private func refreshVideoOutputAfterResume() {
        #if os(iOS)
        // Re-selecting the active video track nudges VLCKit to rebuild the
        // video output when audio has resumed but rendering is still stale.
        guard let selectedTrack = mediaPlayer.videoTracks.first(where: \.isSelected)
            ?? mediaPlayer.videoTracks.first else {
            return
        }

        selectedTrack.isSelectedExclusively = true
        renderingHost.invalidatePlaybackState()
        #endif
    }

    private func recoveryStartPosition(for source: PlaybackSource) -> TimeInterval {
        let observed = observedPlayerTime
        let fallback = source.startPosition ?? 0
        return max(0, observed.isFinite && observed > 0 ? observed : max(currentTime, fallback))
    }

    private func finishValidatedLoad(source: PlaybackSource, attemptID: UUID) {
        guard currentAttemptContext?.attemptID == attemptID else { return }

        guard let media = VLCMedia(url: source.url) else {
            failLoad(
                .unknown("Playback failed while opening the direct-play stream."),
                attemptID: attemptID,
                message: "VLCKit could not create media"
            )
            return
        }

        applySubtitleStyling(to: media)
        applyNetworkBufferingOptions(to: media)
        configureAudioOutputPolicy(reason: "before-play")
        mediaPlayer.media = media
        if let rawVideoOutput {
            _ = rawVideoOutput.attach(to: mediaPlayer)
        }
        mediaPlayer.currentSubTitleFontScale = PlaybackSubtitleStyle.vlcSubtitleFontScale
        mediaPlayer.play()
        loadValidationTask = nil
    }

    private func failLoad(_ error: PlaybackError, attemptID: UUID, message: String) {
        guard currentAttemptContext?.attemptID == attemptID else { return }

        if let currentAttemptContext {
            vlcKitEngineLogger.error(
                "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) \(message, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        self.error = error
        state = .error
        isBuffering = false
        loadValidationTask = nil
    }

    private func logStateChange(_ vlcState: VLCMediaPlayerState) {
        let attemptLabel = currentAttemptContext?.attemptLabel ?? "unknown"
        let parsedStatus = String(describing: mediaPlayer.media?.parsedStatus)
        vlcKitEngineLogger.debug(
            "Playback attempt \(attemptLabel, privacy: .public) VLCKit state=\(String(describing: vlcState), privacy: .public) parsedStatus=\(parsedStatus, privacy: .public) currentTime=\(self.currentTime, privacy: .public) duration=\(self.duration, privacy: .public) buffering=\(self.isBuffering, privacy: .public)"
        )
    }

    private func refreshTracks() {
        availableAudioTracks = mediaPlayer.audioTracks.map { track in
            AudioTrack(
                id: Int(track.identifier),
                displayTitle: trackDisplayTitle(for: track),
                language: track.language,
                languageCode: normalizedLanguageCode(from: track.language),
                codec: track.codecName(),
                channels: Int(track.audio?.channelsNumber ?? 0).nonZeroValue,
                channelLayout: nil
            )
        }
        selectedAudioTrackID = mediaPlayer.audioTracks.first(where: \.isSelected).map { Int($0.identifier) }
        configureAudioOutputPolicy(reason: "tracks-refreshed")

        availableSubtitleTracks = mediaPlayer.textTracks.map { track in
            SubtitleTrack(
                id: Int(track.identifier),
                displayTitle: trackDisplayTitle(for: track),
                language: track.language,
                languageCode: normalizedLanguageCode(from: track.language),
                codec: track.codecName(),
                isForced: false,
                isHearingImpaired: false,
                isExternal: false,
                externalURL: nil
            )
        }
        selectedSubtitleTrackID = mediaPlayer.textTracks.first(where: \.isSelected).map { Int($0.identifier) }
    }

    private func trackDisplayTitle(for track: VLCMediaPlayer.Track) -> String {
        if !track.trackName.isEmpty {
            return track.trackName
        }

        if let description = track.trackDescription, !description.isEmpty {
            return description
        }

        if let language = track.language, !language.isEmpty {
            return language
        }

        return "Unknown"
    }

    private func normalizedLanguageCode(from language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        return language.lowercased()
    }

    private func configureAudioOutputPolicy(reason: String = "initial") {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs
        let selectedTrack = selectedVLCTrack()
        let selectedTrackLabel = selectedTrack.map { self.trackDisplayTitle(for: $0) } ?? "Unknown"
        let selectedChannels = selectedTrack.flatMap { Int($0.audio?.channelsNumber ?? 0).nonZeroValue }
        let outputChannelCount = max(
            Int(session.outputNumberOfChannels),
            outputs.compactMap { $0.channels?.count }.max() ?? 0
        )
        let maximumOutputChannelCount = max(Int(session.maximumOutputNumberOfChannels), outputChannelCount)
        let targetMixMode = desiredAudioMixMode(forChannelCount: selectedChannels)
        let preferredOutputChannels = preferredOutputChannelCount(for: targetMixMode)

        if #available(iOS 15.0, tvOS 15.0, *) {
            do {
                try session.setSupportsMultichannelContent(true)
            } catch {
                vlcKitEngineLogger.debug(
                    "Failed to opt in to multichannel audio session content support: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if let preferredOutputChannels,
           maximumOutputChannelCount >= preferredOutputChannels,
           session.preferredOutputNumberOfChannels != preferredOutputChannels {
            do {
                try session.setPreferredOutputNumberOfChannels(preferredOutputChannels)
            } catch {
                vlcKitEngineLogger.debug(
                    "Failed to set preferred output channel count \(preferredOutputChannels, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        mediaPlayer.audio?.passthrough = false
        mediaPlayer.equalizer = nil
        if mediaPlayer.audioMixMode != targetMixMode {
            mediaPlayer.audioMixMode = targetMixMode
        }
        lastAppliedAudioMixMode = mediaPlayer.audioMixMode

        let routeSummary = outputs.map { output in
            let channelCount = output.channels?.count ?? 0
            if #available(iOS 15.0, tvOS 15.0, *) {
                return "\(output.portType.rawValue){channels=\(channelCount), spatial=\(output.isSpatialAudioEnabled)}"
            } else {
                return "\(output.portType.rawValue){channels=\(channelCount)}"
            }
        }.joined(separator: ", ")

        playbackDiagnostics = [
            PlaybackEngineDiagnostic(
                label: "VLC Audio Track",
                value: "\(selectedTrackLabel) / \(selectedChannels.map { "\($0)ch" } ?? "unknown channels")"
            ),
            PlaybackEngineDiagnostic(
                label: "VLC Audio Output",
                value: "mix=\(self.audioMixModeLabel(self.lastAppliedAudioMixMode)), passthrough=\(self.mediaPlayer.audio?.passthrough == true ? "On" : "Off")"
            ),
            PlaybackEngineDiagnostic(
                label: "Audio Route",
                value: routeSummary.isEmpty ? "Unknown" : routeSummary
            ),
            PlaybackEngineDiagnostic(
                label: "Output Channels",
                value: "current=\(outputChannelCount), preferred=\(session.preferredOutputNumberOfChannels), max=\(maximumOutputChannelCount)"
            ),
        ]

        vlcKitEngineLogger.notice(
            "Applied VLC audio policy reason=\(reason, privacy: .public) selectedTrack=\(selectedTrackLabel, privacy: .public) selectedChannels=\(selectedChannels ?? 0, privacy: .public) mixMode=\(self.audioMixModeLabel(self.lastAppliedAudioMixMode), privacy: .public) passthrough=false outputChannels=\(outputChannelCount, privacy: .public) preferredOutputChannels=\(session.preferredOutputNumberOfChannels, privacy: .public) maxOutputChannels=\(maximumOutputChannelCount, privacy: .public) route=[\(routeSummary, privacy: .public)]"
        )
        #endif
    }

    private func selectedVLCTrack() -> VLCMediaPlayer.Track? {
        if let selectedAudioTrackID,
           let track = mediaPlayer.audioTracks.first(where: { Int($0.identifier) == selectedAudioTrackID }) {
            return track
        }

        return mediaPlayer.audioTracks.first(where: \.isSelected)
            ?? mediaPlayer.audioTracks.first
    }

    private func desiredAudioMixMode(forChannelCount channels: Int?) -> VLCMediaPlayer.AudioMixMode {
        guard let channels else { return .modeUnset }

        if channels >= 8 {
            return .mode7_1
        }
        if channels >= 6 {
            return .mode5_1
        }
        if channels >= 4 {
            return .mode4_0
        }

        return .modeUnset
    }

    private func preferredOutputChannelCount(for mode: VLCMediaPlayer.AudioMixMode) -> Int? {
        switch mode {
        case .mode7_1:
            8
        case .mode5_1:
            6
        case .mode4_0:
            4
        default:
            nil
        }
    }

    private func audioMixModeLabel(_ mode: VLCMediaPlayer.AudioMixMode) -> String {
        switch mode {
        case .modeUnset:
            "Unset"
        case .modeStereo:
            "Stereo"
        case .modeBinaural:
            "Binaural"
        case .mode4_0:
            "4.0"
        case .mode5_1:
            "5.1"
        case .mode7_1:
            "7.1"
        @unknown default:
            String(describing: mode)
        }
    }

    private func registerAudioSessionObserversIfNeeded() {
        #if os(iOS) || os(tvOS)
        let notifications: [Notification.Name] = {
            var names: [Notification.Name] = [
                AVAudioSession.routeChangeNotification,
            ]
            if #available(iOS 15.0, tvOS 15.0, *) {
                names.append(AVAudioSession.spatialPlaybackCapabilitiesChangedNotification)
            }
            if #available(iOS 17.2, tvOS 17.2, *) {
                names.append(AVAudioSession.renderingCapabilitiesChangeNotification)
                names.append(AVAudioSession.renderingModeChangeNotification)
            }
            return names
        }()

        for name in notifications {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.configureAudioOutputPolicy(reason: name.rawValue)
                }
            }
            audioSessionObservers.append(observer)
        }
        #endif
    }
}

extension VLCKitEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.handleStateChange(newState)
        }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        let timeMs = mediaPlayer.time.intValue
        Task { @MainActor [weak self] in
            self?.updateTime(timeMs: timeMs, lengthMs: Int32(length))
            self?.renderingHost.invalidatePlaybackState()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let timeMs = mediaPlayer.time.intValue
        let lengthMs = mediaPlayer.media?.length.intValue ?? 0
        Task { @MainActor [weak self] in
            self?.updateTime(timeMs: timeMs, lengthMs: lengthMs)
        }
    }

    nonisolated func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in
            self?.refreshTracks()
        }
    }

    nonisolated func mediaPlayerTrackRemoved(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in
            self?.refreshTracks()
        }
    }

    nonisolated func mediaPlayerTrackUpdated(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in
            self?.refreshTracks()
        }
    }

    nonisolated func mediaPlayerTrackSelected(
        _ trackType: VLCMedia.TrackType,
        selectedId: String,
        unselectedId: String
    ) {
        Task { @MainActor [weak self] in
            self?.refreshTracks()
        }
    }
}

private struct VLCPlayerRepresentable: UIViewRepresentable {
    let playerView: UIView

    func makeUIView(context: Context) -> UIView {
        playerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private extension Int {
    var nonZeroValue: Int? {
        self == 0 ? nil : self
    }
}
#endif
