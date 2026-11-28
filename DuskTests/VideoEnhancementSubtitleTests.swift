import Foundation
import Testing
#if os(tvOS)
import AVFoundation
import SwiftUI
#endif
@testable import Dusk

@Suite("Video enhancement subtitle eligibility")
struct VideoEnhancementSubtitleTests {
    @Test(arguments: [VideoEnhancementMode.automatic, .enabled, .disabled])
    func embeddedTracksDoNotOverrideThePreference(mode: VideoEnhancementMode) throws {
        // Includes a Plex-selected/default/forced track: metadata alone does
        // not say what the local engine is actually displaying.
        let media = try mediaWithStreams(#"""
            {"id":2,"streamType":1,"codec":"h264","width":1280,"height":720,"frameRate":24},
            {"id":3,"streamType":3,"codec":"mov_text","selected":true,"default":true,"forced":true},
            {"id":4,"streamType":3,"codec":"pgs"}
            """#)
        let request = VideoEnhancementRequest.make(mode: mode, media: media, part: media.parts[0])
        #expect(request.mode == mode)
        #expect(request.disabledReason == nil)
        #expect(request.sourceWidth == 1280)
        #expect(request.sourceHeight == 720)
        #expect(request.frameRate == 24)
    }

    @Test func sidecarTracksDoNotDisableEnhancement() throws {
        let media = try mediaWithStreams(#"""
            {"id":3,"streamType":3,"codec":"srt","key":"/library/streams/3","selected":true}
            """#)
        let request = VideoEnhancementRequest.make(mode: .enabled, media: media, part: media.parts[0])
        #expect(request.isPotentiallyEnabled)
        #expect(request.disabledReason == nil)
    }

    @Test(arguments: [VideoEnhancementMode.automatic, .enabled])
    func avPlayerRequiresNativeRenderingOnlyWhileSubtitlesAreSelected(mode: VideoEnhancementMode) throws {
        let request = VideoEnhancementRequest(mode: mode)
        #expect(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: false) == nil)
        let status = try #require(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: true))
        #expect(status.state == .disabled)
        #expect(status.reason == "Native AVPlayer renderer required while subtitles are selected")
        // The request survives the temporary native-renderer fallback, so Off
        // in the subtitle picker immediately makes enhancement eligible again.
        #expect(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: false) == nil)
        #expect(request.mode == mode)
    }

    @Test(arguments: [false, true])
    func vlcCompositedSubtitlesRemainEligible(isSelected: Bool) {
        let request = VideoEnhancementRequest(mode: .enabled)
        #expect(request.nativeSubtitleRenderingStatus(engine: .vlcKit, hasSelectedSubtitle: isSelected) == nil)
        #expect(request.isPotentiallyEnabled)
    }

    @Test func explicitOffStillReportsThePreference() {
        let request = VideoEnhancementRequest.disabled
        #expect(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: true) == nil)
        #expect(request.nonRenderingStatus == .disabled)
    }

    @Test func hdrAndFrameRateLimitsKeepTheirOwnReasons() throws {
        let media = try mediaWithStreams(#"""
            {"id":2,"streamType":1,"codec":"hevc","bitDepth":10,"frameRate":24},
            {"id":3,"streamType":3,"codec":"pgs"}
            """#)
        let hdrRequest = VideoEnhancementRequest.make(mode: .automatic, media: media, part: media.parts[0])
        let requests = [
            hdrRequest,
            VideoEnhancementRequest(mode: .automatic, frameRate: 60),
            VideoEnhancementRequest(mode: .enabled, frameRate: 120),
        ]
        let reasons = ["Auto skips HDR", "Auto skips >50fps", "Disabled above 70fps"]
        for (request, reason) in zip(requests, reasons) {
            #expect(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: true) == nil)
            #expect(request.nonRenderingStatus.state == .unavailable)
            #expect(request.nonRenderingStatus.reason == reason)
        }
    }

    @Test(arguments: [VideoEnhancementMode.automatic, .enabled])
    func sdrEmbeddedSubtitleEngineChoiceIsTVOnly(mode: VideoEnhancementMode) throws {
        let media = try engineSelectionMedia(videoFields: #","bitDepth":8"#)
        let decision = directDecision(media, mode: mode, subtitleID: "3")
        #if os(tvOS)
        #expect(decision.engine == .vlcKit)
        #expect(decision.usesEnhancedSubtitleRenderer)
        #else
        #expect(decision.engine == .avPlayer)
        #expect(!decision.usesEnhancedSubtitleRenderer)
        #endif
    }

    @Test func subtitleOffSidecarsAndDisabledEnhancementKeepTheNormalEngine() throws {
        let media = try engineSelectionMedia(videoFields: #","bitDepth":8"#)
        // Metadata says selected/default/forced, but an actual Off choice wins.
        for subtitleID: String? in [nil, "4", "999"] {
            let decision = directDecision(media, mode: .enabled, subtitleID: subtitleID)
            #expect(decision.engine == .avPlayer)
            #expect(!decision.usesEnhancedSubtitleRenderer)
        }
        #expect(directDecision(media, mode: .disabled, subtitleID: "3").engine == .avPlayer)
    }

    /// 10-bit H.264 is Hi10P: AVPlayer has no hardware decoder, so the
    /// resolver picks VLCKit. That choice is the codec path, not the tvOS
    /// enhancement handoff, which still rejects anything above 8-bit.
    @Test(arguments: [VideoEnhancementMode.automatic, .enabled])
    func tenBitH264GoesToVLCKitWithoutTheEnhancementOverride(mode: VideoEnhancementMode) throws {
        let media = try engineSelectionMedia(videoFields: #","bitDepth":10"#)
        let decision = directDecision(media, mode: mode, subtitleID: "3")
        #expect(decision.engine == .vlcKit)
        #expect(decision.reason.contains("10-bit H.264"))
        #expect(!decision.usesEnhancedSubtitleRenderer)
    }

    @Test(arguments: [
        #","colorTrc":"smpte2084""#,
        #","bitDepth":8,"colorTrc":"arib-std-b67""#,
        #","bitDepth":8,"profile":"HDR10+""#,
        #","bitDepth":8,"colorPrimaries":"bt2020""#,
        #","bitDepth":8,"DOVIPresent":true"#,
        #","bitDepth":8,"DOVIProfile":5"#,
        #","bitDepth":8,"DOVIProfile":7"#,
        #","bitDepth":8,"DOVIProfile":8,"DOVIBLCompatID":1"#,
        #","bitDepth":8,"DOVIProfile":8,"DOVIBLCompatID":4"#,
        #","bitDepth":8,"DOVIBLCompatID":1"#,
        #","bitDepth":8,"DOVILevel":6"#,
        "", // Missing video range metadata must not be assumed SDR.
    ])
    func hdrDolbyVisionAndUnknownRangeNeverGetTheOverride(videoFields: String) throws {
        let media = try engineSelectionMedia(videoFields: videoFields)
        for mode: VideoEnhancementMode in [.automatic, .enabled] {
            let decision = directDecision(media, mode: mode, subtitleID: "3")
            #expect(decision.engine == .avPlayer)
            #expect(!decision.usesEnhancedSubtitleRenderer)
        }
    }

    @Test func sdrTransferCanEstablishRangeWithoutBitDepth() throws {
        let media = try engineSelectionMedia(videoFields: #","colorTrc":"bt709""#)
        let decision = directDecision(media, mode: .enabled, subtitleID: "3")
        #if os(tvOS)
        #expect(decision.usesEnhancedSubtitleRenderer)
        #else
        #expect(decision.engine == .avPlayer)
        #endif
    }

    @Test func sdrContainersThatNeedVLCCanAlsoPreferEnhancementOverTheAtmosRemux() throws {
        let media = try engineSelectionMedia(videoFields: #","bitDepth":8"#, container: "mkv")
        let decision = directDecision(media, mode: .enabled, subtitleID: "3")
        #expect(decision.engine == .vlcKit)
        #if os(tvOS)
        #expect(decision.usesEnhancedSubtitleRenderer)
        #else
        #expect(!decision.usesEnhancedSubtitleRenderer)
        #endif
        let hdr = try engineSelectionMedia(videoFields: #","colorTrc":"smpte2084""#, container: "mkv")
        #expect(!directDecision(hdr, mode: .enabled, subtitleID: "3").usesEnhancedSubtitleRenderer)
    }

    @Test func frameRateLimitsAndExplicitEngineOverridesStillWin() throws {
        let media = try engineSelectionMedia(videoFields: #","bitDepth":8,"frameRate":120"#)
        #expect(directDecision(media, mode: .enabled, subtitleID: "3").engine == .avPlayer)
        let autoSkipped = try engineSelectionMedia(videoFields: #","bitDepth":8,"frameRate":60"#)
        #expect(directDecision(autoSkipped, mode: .automatic, subtitleID: "3").engine == .avPlayer)
        let sdr = try engineSelectionMedia(videoFields: #","bitDepth":8"#)
        let forcedAV = StreamResolver.evaluateForDirectPlayback(
            media: sdr, part: sdr.parts[0], enhancementMode: .enabled,
            selectedSubtitleStreamID: "3", forceAVPlayer: true
        )
        #expect(forcedAV.engine == .avPlayer)
        #expect(!forcedAV.usesEnhancedSubtitleRenderer)
        let forcedVLC = StreamResolver.evaluateForDirectPlayback(
            media: sdr, part: sdr.parts[0], enhancementMode: .disabled,
            selectedSubtitleStreamID: nil, forceVLCKit: true
        )
        #expect(forcedVLC.engine == .vlcKit)
        #expect(!forcedVLC.usesEnhancedSubtitleRenderer)
    }

    private func directDecision(
        _ media: MediaVersion, mode: VideoEnhancementMode, subtitleID: String?
    ) -> StreamResolver.Decision {
        StreamResolver.evaluateForDirectPlayback(
            media: media, part: media.parts[0], enhancementMode: mode,
            selectedSubtitleStreamID: subtitleID
        )
    }

    private func engineSelectionMedia(videoFields: String, container: String = "mp4") throws -> MediaVersion {
        try JSONDecoder().decode(MediaVersion.self, from: Data("""
            {"id":1,"container":"\(container)","videoCodec":"h264","audioCodec":"aac","Part":[
              {"id":1,"key":"/clip.mp4","Stream":[
                {"id":2,"streamType":1,"codec":"h264"\(videoFields)},
                {"id":10,"streamType":2,"codec":"aac","channels":2,"default":true},
                {"id":11,"streamType":2,"codec":"ac3","channels":6},
                {"id":3,"streamType":3,"codec":"mov_text","selected":true,"default":true,"forced":true},
                {"id":4,"streamType":3,"codec":"srt","key":"/library/streams/4"}
              ]}
            ]}
            """.utf8))
    }

    #if os(tvOS)
    @Test @MainActor
    func automaticEmbeddedSelectionReportsTheDiscoveredPlexTrack() throws {
        let media = try engineSelectionMedia(videoFields: #","bitDepth":8"#)
        let player = PlayerViewModel(engine: SubtitleHandoffEngine(state: .playing))
        defer { player.cleanup() }
        player.hasConfiguredAutomaticTrackSelection = true
        player.hasAppliedAutomaticAudioSelection = true
        player.subtitlePolicy = SubtitleSelectionPolicy(
            mode: .off, subtitleLanguage: nil, audioLanguage: nil, forcedSubtitlesEnabled: true
        )
        player.subtitleTracks = media.parts[0].streams.filter { $0.id == "3" }.map(SubtitleTrack.init(stream:))
        player.audioTracks = media.parts[0].streams.filter { $0.id == "11" }.map(AudioTrack.init(stream:))
        player.selectedAudioTrackID = 11
        var reported: ExplicitTrackSelection?
        player.plexTrackSelectionHandler = { audioID, subtitleID in
            reported = ExplicitTrackSelection(audioStreamID: audioID, subtitleStreamID: subtitleID)
        }
        player.applyAutomaticTrackSelectionIfNeeded()
        #expect(reported == ExplicitTrackSelection(audioStreamID: "11", subtitleStreamID: "3"))
    }

    @Test @MainActor
    func liveHandoffRetainsPositionTracksPauseStateAndDownloadIdentity() throws {
        let preferences = UserPreferences()
        let previousMode = preferences.videoEnhancementMode
        let previousForceAV = preferences.forceAVPlayer
        let previousForceVLC = preferences.forceVLCKit
        defer {
            preferences.videoEnhancementMode = previousMode
            preferences.forceAVPlayer = previousForceAV
            preferences.forceVLCKit = previousForceVLC
        }
        preferences.videoEnhancementMode = .enabled
        preferences.forceAVPlayer = false
        preferences.forceVLCKit = false
        let media = try engineSelectionMedia(videoFields: #","bitDepth":8"#)
        let encodedMedia = String(decoding: try JSONEncoder().encode(media), as: UTF8.self)
        let details = try JSONDecoder().decode(MediaDetails.self, from: Data("""
            {"ratingKey":"1","key":"/library/metadata/1","type":"movie","title":"SDR","Media":[\(encodedMedia)]}
            """.utf8))

        for isDownload in [false, true] {
            for initialState: PlaybackState in [.playing, .paused] {
                let playback = PlaybackCoordinator(plexService: PlexService(), preferences: preferences)
                defer { playback.cancelDirectPlayFallbackWatch(); playback.engine?.stop() }
                let oldEngine = SubtitleHandoffEngine(state: initialState)
                playback.engine = oldEngine
                playback.itemID = "1"
                playback.activeItemDetails = details
                playback.activePlaybackSessionIdentifier = "existing-session"
                playback.activePlaybackUsesLocalDownload = isDownload
                playback.hasScrobbled = true
                playback.activeAudioStreamID = "11"
                let url = try #require(URL(string: isDownload ? "file:///tmp/clip.mp4" : "https://example.invalid/clip.mp4"))
                let context = PlaybackAttemptContext(
                    attemptID: UUID(), title: "SDR", itemID: "1", engine: .avPlayer,
                    resolverReason: "MP4", mediaID: "1", partID: "1", sanitizedPlaybackURL: url.absoluteString
                )
                playback.debugInfo = PlaybackDebugInfo(
                    title: "SDR", engine: .avPlayer, decision: isDownload ? .localDownload : .directPlay,
                    media: media, part: media.parts[0], attemptID: context.attemptID,
                    resolverReason: "MP4", sanitizedPlaybackURL: url.absoluteString
                )
                // The live clock is behind the original resume position after
                // a backwards seek. Also exercise play after a paused start.
                playback.playbackSource = PlaybackSource(
                    url: url, startPosition: 100, shouldAutoPlay: initialState == .paused, context: context
                )
                let presentationID = playback.playerPresentationID
                playback.selectPlexStreamsForPlayback(audioStreamID: "11", subtitleStreamID: "3")
                #expect(oldEngine.didStop)
                #expect(playback.engine is VLCKitEngine)
                #expect(playback.debugInfo?.engine == .vlcKit)
                #expect(playback.playbackSource?.url == url)
                #expect(playback.playbackSource?.startPosition == 42)
                #expect(playback.playbackSource?.shouldAutoPlay == (initialState == .playing))
                #expect(playback.playbackSource?.preferredAudioTrackPosition == 1)
                #expect(playback.playbackSource?.preferredAudioChannelCount == 6)
                #expect(playback.activePlaybackUsesLocalDownload == isDownload)
                #expect(playback.activePlaybackSessionIdentifier == "existing-session")
                #expect(playback.hasScrobbled)
                #expect(playback.playerPresentationID != presentationID)
                #expect(playback.consumePendingExplicitTrackSelection() == ExplicitTrackSelection(audioStreamID: "11", subtitleStreamID: "3"))
                #expect(playback.consumePendingExplicitTrackSelection() == nil)
                let vlcPresentationID = playback.playerPresentationID
                for subtitleID: String? in [nil, "3", nil, "3", nil] {
                    playback.selectPlexStreamsForPlayback(audioStreamID: "11", subtitleStreamID: subtitleID)
                    #expect(playback.playerPresentationID == vlcPresentationID)
                    #expect(playback.debugInfo?.engine == .vlcKit)
                    #expect(playback.playbackSource?.url == url)
                }
            }
        }
    }
    #endif

    private func mediaWithStreams(_ streams: String) throws -> MediaVersion {
        try JSONDecoder().decode(MediaVersion.self, from: Data("""
            {"id":1,"Part":[{"id":1,"key":"/clip","Stream":[\(streams)]}]}
            """.utf8))
    }
}

#if os(tvOS)
@MainActor
private final class SubtitleHandoffEngine: PlaybackEngine {
    let state: PlaybackState
    let currentTime: TimeInterval = 42
    let duration: TimeInterval = 300
    let isBuffering = false
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    var onPlaybackEnded: (@MainActor () -> Void)?
    private let player = AVPlayer()
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }
    private(set) var didStop = false

    init(state: PlaybackState) { self.state = state }
    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func play() {}
    func pause() {}
    func stop() { didStop = true }
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
#endif
