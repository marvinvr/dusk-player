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
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)
    func recoverFromStall()

    /// Called when the app returns to foreground after being backgrounded.
    /// Engines should restore their video rendering pipeline here.
    func handleReturnToForeground()

    // MARK: - State

    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isBuffering: Bool { get }
    var error: PlaybackError? { get }
    var onPlaybackEnded: (@MainActor () -> Void)? { get set }

    // MARK: - Track Selection

    var availableSubtitleTracks: [SubtitleTrack] { get }
    var availableAudioTracks: [AudioTrack] { get }
    var selectedSubtitleTrackID: Int? { get }
    var selectedAudioTrackID: Int? { get }
    func selectSubtitleTrack(_ track: SubtitleTrack?)
    func selectAudioTrack(_ track: AudioTrack)

    // MARK: - Rendering

    /// Returns a platform-specific view that renders the video content.
    func makePlayerView() -> AnyView

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
