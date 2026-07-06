import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Which concrete engine to use for playback.
enum PlaybackEngineType: Sendable {
    case avPlayer
    case vlcKit
}

enum PlaybackBufferPolicy {
    static let avPlayerForwardBufferDuration: TimeInterval = 20

    /// libvlc caching is NOT just a network buffer: it becomes the input's
    /// pts_delay, which scales every clock window in the pipeline — the
    /// initial dejitter offset, the audio output's start deferral after
    /// open/seek/flush, and the late/early drift thresholds. At 8000 ms these
    /// windows stretched to many seconds: audio could sit "deferred"/"late"
    /// (silent, no error anywhere) for seconds after every start and every
    /// seek, while a pause of a few seconds happened to shift the clocks past
    /// the gap — which is why a manual pause→play "cured" it. VLC-iOS ships
    /// 999 ms by default on the same stack; 1500 ms keeps some headroom while
    /// keeping every sync window comfortably sub-perceptual.
    static let vlcNetworkCachingMilliseconds = 1_500
    static let vlcFileCachingMilliseconds = 1_500
}

struct PlaybackEngineDiagnostic: Sendable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Receives Picture in Picture lifecycle events from a `PlaybackEngine` so the
/// owner (the coordinator) can keep the session alive while the floating window
/// is shown and restore the player UI when the user returns from it.
@MainActor
protocol PlaybackPictureInPictureDelegate: AnyObject {
    /// The floating window started (`true`) or stopped (`false`).
    func pictureInPictureActiveDidChange(_ isActive: Bool)

    /// The user asked to return to the full app UI from the PiP window. Call
    /// `completion(true)` once the player UI is back on screen so the system can
    /// animate the video back into place.
    func pictureInPictureRestorePlayerUI(completion: @escaping (Bool) -> Void)
}

/// Unified interface for media playback. Concrete implementations wrap
/// AVPlayer (`AVPlayerEngine`) or VLCKit (`VLCKitEngine`).
///
/// Implementations must be `@Observable` so SwiftUI views can react
/// to state changes (currentTime, playback state, track lists, etc.).
@MainActor
protocol PlaybackEngine: AnyObject {
    // MARK: - Lifecycle

    /// Begin loading media from the given URL. If `startPosition` is non-nil,
    /// seek to that offset once loaded (resume playback).
    func load(source: PlaybackSource)
    func configureVideoEnhancement(_ request: VideoEnhancementRequest)
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)

    /// Seek with a precision hint. `precise: false` lets the engine trade
    /// frame accuracy for speed (e.g. AVPlayer snapping to a nearby keyframe
    /// instead of decoding up to the exact frame) — meant for transient jumps
    /// like double-tap/remote skips where the position is approximate anyway.
    /// `precise: true` behaves like `seek(to:)`. Engines that don't
    /// distinguish keep the default, which forwards to `seek(to:)`.
    func seek(to position: TimeInterval, precise: Bool)
    func recoverFromStall()

    /// Called when the app returns to foreground after being backgrounded.
    /// Engines should restore their video rendering pipeline here.
    func handleReturnToForeground()

    /// Toggles how the video fills its container. `false` letterboxes the video
    /// to fit (aspect fit); `true` zooms it to fill the container, cropping the
    /// overflow (aspect fill). Driven by the iOS/iPadOS player zoom control;
    /// tvOS does not call this.
    func setVideoFillEnabled(_ enabled: Bool)

    // MARK: - State

    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isBuffering: Bool { get }
    var error: PlaybackError? { get }
    var videoEnhancementStatus: VideoEnhancementStatus { get }
    var onPlaybackEnded: (@MainActor () -> Void)? { get set }
    var playbackDiagnostics: [PlaybackEngineDiagnostic] { get }

    // MARK: - Track Selection

    var availableSubtitleTracks: [SubtitleTrack] { get }
    var availableAudioTracks: [AudioTrack] { get }
    var selectedSubtitleTrackID: Int? { get }
    var selectedAudioTrackID: Int? { get }
    func selectSubtitleTrack(_ track: SubtitleTrack?)
    func selectAudioTrack(_ track: AudioTrack)

    /// Whether automatic (app-driven) audio track selection may run right now.
    /// VLCKit defers it until playback is steadily rendering: switching the
    /// audio ES restarts libvlc's audio output (input format change), and doing
    /// that inside the startup window — output bring-up, audio session
    /// activation, resume seek — can leave the restarted output dead until a
    /// manual pause/resume. Steady-state switches are safe.
    var isReadyForAutomaticAudioSelection: Bool { get }

    // MARK: - Audio session

    /// Whether this engine wants the rich `.moviePlayback` audio session, which
    /// lets iOS spatialize audio for AirPods. AVPlayer feeds that spatializer
    /// natively and smoothly; VLCKit's raw audio output does not, and on a
    /// Bluetooth route it underruns and stutters, so it opts out for a plain,
    /// unprocessed session. iOS only — consumed by `PlaybackNowPlayingController`.
    var prefersSpatializedAudioSession: Bool { get }

    // MARK: - Rendering

    /// Returns a platform-specific view that renders the video content.
    func makePlayerView() -> AnyView

    /// Bumped when the engine replaces its rendering view mid-session (VLCKit
    /// entering Picture in Picture support mode); `PlayerViewModel` re-calls
    /// `makePlayerView()` when it changes. Engines with a stable view keep the
    /// default 0.
    var playerViewGeneration: Int { get }

    // MARK: - Picture in Picture

    /// Whether Picture in Picture can be started (or, for VLCKit's on-demand
    /// support mode, prepared) right now. iOS only.
    var isPictureInPicturePossible: Bool { get }

    /// Whether a Picture in Picture window is currently active.
    var isPictureInPictureActive: Bool { get }

    /// Routes PiP lifecycle events back to the owner. Held weakly.
    func setPictureInPictureDelegate(_ delegate: (any PlaybackPictureInPictureDelegate)?)

    func startPictureInPicture()
    func stopPictureInPicture()

}

extension PlaybackEngine {
    var playbackDiagnostics: [PlaybackEngineDiagnostic] { [] }
    func setVideoFillEnabled(_ enabled: Bool) {}

    // Bumped when the engine replaces its rendering view mid-session (VLCKit
    // entering Picture in Picture support mode); `PlayerViewModel` re-calls
    // `makePlayerView()` when it changes. Engines with a stable view keep 0.
    var playerViewGeneration: Int { 0 }

    // Default: the precision hint is ignored — only AVPlayer distinguishes
    // tolerant (keyframe) seeks from frame-accurate ones.
    func seek(to position: TimeInterval, precise: Bool) {
        seek(to: position)
    }

    // Default: no startup fragility — only VLCKit defers automatic selection.
    var isReadyForAutomaticAudioSelection: Bool { true }

    // Default: keep the rich movie-playback session. Only VLCKit opts out.
    var prefersSpatializedAudioSession: Bool { true }

    // Picture in Picture is iOS-only and opt-in per engine; tvOS engines and
    // the Metal video-enhancement render path fall back to these no-ops.
    var isPictureInPicturePossible: Bool { false }
    var isPictureInPictureActive: Bool { false }
    func setPictureInPictureDelegate(_ delegate: (any PlaybackPictureInPictureDelegate)?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
}

@MainActor
enum PlaybackSubtitleStyle {
    static var avPlayerRelativeFontSize: Int {
        switch userInterfaceIdiom {
        case .pad, .mac:
            return 75
        default:
            return 100
        }
    }

    static var vlcSubtitleFontScale: Float {
        Float(avPlayerRelativeFontSize) / 100
    }

    private static var userInterfaceIdiom: UIUserInterfaceIdiom {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom
        #else
        .unspecified
        #endif
    }
}
