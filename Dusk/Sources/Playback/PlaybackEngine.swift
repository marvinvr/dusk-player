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
    static let vlcNetworkCachingMilliseconds = 8_000
    static let vlcFileCachingMilliseconds = 8_000
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

    // MARK: - Picture in Picture

    /// Whether Picture in Picture can be started right now: the device supports
    /// it, the engine renders to a native layer (not the Metal enhancement
    /// path), and the system controller is ready. iOS only.
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
