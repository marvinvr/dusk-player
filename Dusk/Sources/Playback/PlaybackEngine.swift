import SwiftUI

/// Which concrete engine to use for playback.
enum PlaybackEngineType: Sendable {
    case avPlayer
    case vlcKit
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
    func load(url: URL, startPosition: TimeInterval?)
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)

    // MARK: - State

    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isBuffering: Bool { get }
    var error: PlaybackError? { get }

    // MARK: - Track Selection

    var availableSubtitleTracks: [SubtitleTrack] { get }
    var availableAudioTracks: [AudioTrack] { get }
    func selectSubtitleTrack(_ track: SubtitleTrack?)
    func selectAudioTrack(_ track: AudioTrack)

    // MARK: - Rendering

    /// Returns a platform-specific view that renders the video content.
    func makePlayerView() -> AnyView
}
