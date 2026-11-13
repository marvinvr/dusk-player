import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Which concrete engine to use for playback.
enum PlaybackEngineType: Sendable {
    case avPlayer
    case vlcKit
}

/// Where a playback source's bytes actually come from, resolved by the
/// coordinator when the source is built. Drives how much protective buffering
/// the engine needs: a downloaded file has no jitter at all, a LAN Plex
/// server very little, and only a remote/relay stream needs real headroom.
enum PlaybackSourceLocality: Sendable {
    case localFile
    case localNetwork
    case remoteNetwork
}

enum PlaybackBufferPolicy {
    static let avPlayerForwardBufferDuration: TimeInterval = 20

    /// libvlc caching is NOT just a network buffer: it becomes the input's
    /// pts_delay, which scales every clock window in the pipeline — the
    /// initial dejitter offset, the audio output's start deferral after
    /// open/seek/flush, and the late/early drift thresholds. In practice the
    /// caching value IS the stretch of silent video that opens every session
    /// and follows every seek: the first picture renders right away while the
    /// audio output sits in its deferred start for ~the caching duration (at
    /// the old flat 1500 ms, every start played ~1.5 s of video before any
    /// sound; at the pre-migration 8000 ms it was many seconds). So the value
    /// is tiered by how much jitter the transport can actually produce, and
    /// each tier sits as low as that transport safely allows: a downloaded
    /// file has none (300 ms is VLC's own file-access default), a LAN server
    /// very little, and only remote/relay streams keep the protective
    /// headroom (VLC-iOS ships 999 ms as its blanket network default).
    static func vlcCachingMilliseconds(for locality: PlaybackSourceLocality) -> Int {
        switch locality {
        case .localFile: 300
        case .localNetwork: 600
        case .remoteNetwork: 1_500
        }
    }
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
    /// Changes the rate of active playback without changing the paused/playing
    /// state. The player UI uses this for its temporary iOS/iPadOS hold-to-2x
    /// interaction and restores the normal `1` rate when the hold ends.
    func setPlaybackRate(_ rate: Float)

    // MARK: - Coordinated playback

    /// Apple's transport coordinator for this engine. AVPlayer supplies one
    /// natively; VLCKit is adapted through AVDelegatingPlaybackCoordinator.
    var playbackCoordinator: AVPlaybackCoordinator { get }

    /// Sets the stable server-scoped identity used to match this item with the
    /// copies loaded by other SharePlay participants. Nil detaches local custom
    /// playback behavior after leaving the group.
    func configureCoordinatedPlayback(itemIdentifier: String?)

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

    /// Applies the user's subtitle size preference. The coordinator calls this
    /// once with the stored preference right after building the engine (before
    /// `load(source:)`, so per-media options can carry it); the in-player picker
    /// calls it again for a live change. A change made in Settings reaches the
    /// engine on the next session, since Settings is not reachable while the
    /// player is up.
    func applySubtitleFontSize(_ size: SubtitleFontSize)

    /// Applies the user's subtitle look (system caption style or Dusk's own).
    /// Called with `applySubtitleFontSize(_:)` before `load(source:)`; it is
    /// only changed in Settings, so a change reaches the next session.
    func applySubtitleStyle(_ style: SubtitleStyle)

    /// Raises the subtitles above an overlay resting on the bottom of the
    /// player (the Up Next poster), or back to their normal place when nil.
    /// Moves what is on screen smoothly and draws nothing by itself, so with
    /// subtitles off or between cues there is no visible change at all.
    func setSubtitleClearance(_ clearance: SubtitleClearance?)

    /// Whether `setAudioDelay(milliseconds:)` does anything. Only VLCKit can
    /// shift audio against video; AVPlayer has no such control (#67).
    var supportsAudioDelay: Bool { get }

    /// Manual audio sync: positive delays the audio, negative brings it
    /// earlier. Callable before `load(source:)` (the value then opens with the
    /// media) and live during playback.
    func setAudioDelay(milliseconds: Int)

    // MARK: - State

    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    /// The engine's current transport rate, including temporary speed boosts
    /// and rate changes received through SharePlay. Zero while paused.
    var playbackRate: Float { get }
    /// The currently seekable media-time window. Live HLS commonly starts
    /// above zero and advances at its upper edge as Plex appends segments.
    var seekableTimeRange: ClosedRange<TimeInterval>? { get }
    var isBuffering: Bool { get }
    var error: PlaybackError? { get }
    var videoEnhancementStatus: VideoEnhancementStatus { get }
    var onPlaybackEnded: (@MainActor () -> Void)? { get set }
    var playbackDiagnostics: [PlaybackEngineDiagnostic] { get }
    /// What the engine measures it is playing right now; follows HLS variant
    /// switches. Nil until the first reading. Views merge it with Plex metadata
    /// through `PlaybackDebugInfo.currentVideoQuality(live:)`.
    var currentVideoQuality: PlaybackVideoQuality? { get }

    // MARK: - Track Selection

    var availableSubtitleTracks: [SubtitleTrack] { get }
    var availableAudioTracks: [AudioTrack] { get }
    var selectedSubtitleTrackID: Int? { get }
    var selectedAudioTrackID: Int? { get }
    func selectSubtitleTrack(_ track: SubtitleTrack?)
    func selectAudioTrack(_ track: AudioTrack)

    /// Whether the engine can mount an external (sidecar) subtitle file on the
    /// media it is already playing. VLCKit adds one as a libvlc playback slave;
    /// AVPlayer cannot attach a sidecar to a live item at all (it would need an
    /// AVComposition rebuild), so a Plex sidecar there requires restarting the
    /// session on VLCKit.
    var supportsExternalSubtitles: Bool { get }

    /// Mounts a sidecar subtitle file (a Plex `/library/streams/{id}` URL) on
    /// the current media, optionally making it the active subtitle track.
    ///
    /// `codec` identifies text sidecars for encoding normalization; bitmap and
    /// unknown codecs retain their original delivery.
    /// The track appears in `availableSubtitleTracks` asynchronously, carrying
    /// `externalURL == url` so the caller can map it back to the Plex stream it
    /// came from. Returns whether the engine accepted the request, not whether
    /// the file parsed. Engines must remember their mounted slaves and re-add
    /// them whenever they reopen the media in place (slaves live on the input,
    /// not on the media).
    @discardableResult
    func attachExternalSubtitle(_ url: URL, codec: String?, select: Bool) -> Bool

    /// Whether automatic (app-driven) audio track selection may run right now.
    /// VLCKit defers it until playback is steadily rendering: switching the
    /// audio ES restarts libvlc's audio output (input format change), and doing
    /// that inside the startup window — output bring-up, audio session
    /// activation, resume seek — can leave the restarted output dead until a
    /// manual pause/resume. Steady-state switches are safe.
    var isReadyForAutomaticAudioSelection: Bool { get }

    /// An audio track whose decoder turned out not to work during this load
    /// (VLCKit: libvlc reported that it could not open the TrueHD decoder).
    /// The view model hands it to the server audio-conversion fallback once.
    var failedAudioDecoderTrackID: Int? { get }

    // MARK: - Audio session

    /// Whether this engine wants the rich `.moviePlayback` audio session, which
    /// lets iOS spatialize audio for AirPods. AVPlayer feeds that spatializer
    /// natively and smoothly; VLCKit's raw audio output does not, and on a
    /// Bluetooth route it underruns and stutters, so it opts out for a plain,
    /// unprocessed session. iOS only — consumed by `PlaybackNowPlayingController`.
    var prefersSpatializedAudioSession: Bool { get }

    // MARK: - External playback

    /// Whether the engine can hand video to a system external-playback route.
    /// AVPlayer supports native AirPlay; VLCKit's renderer remains local.
    var supportsExternalPlayback: Bool { get }

    /// Whether the engine is currently rendering video on an external route.
    var isExternalPlaybackActive: Bool { get }

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

    #if os(macOS)
    /// The player's own volume (0...1) and mute. Mac video players keep an
    /// in-app volume like QuickTime does; iOS and tvOS follow the system's.
    func setVolume(_ volume: Float, muted: Bool)
    #endif
}

extension PlaybackEngine {
    var playbackRate: Float { state == .playing ? 1 : 0 }

    var seekableTimeRange: ClosedRange<TimeInterval>? {
        duration > 0 ? 0...duration : nil
    }

    var playbackDiagnostics: [PlaybackEngineDiagnostic] { [] }
    var currentVideoQuality: PlaybackVideoQuality? { nil }
    func setVideoFillEnabled(_ enabled: Bool) {}

    // Default: subtitle sizing is engine-specific; engines that render text
    // subtitles themselves override this.
    func applySubtitleFontSize(_ size: SubtitleFontSize) {}
    func applySubtitleStyle(_ style: SubtitleStyle) {}
    func setSubtitleClearance(_ clearance: SubtitleClearance?) {}

    var supportsAudioDelay: Bool { false }
    func setAudioDelay(milliseconds: Int) {}

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

    // Default: decoders are the platform's own. Only VLCKit watches its
    // TrueHD decoder.
    var failedAudioDecoderTrackID: Int? { nil }

    // Default: sidecar subtitles cannot be mounted. Only VLCKit opts in.
    var supportsExternalSubtitles: Bool { false }
    @discardableResult
    func attachExternalSubtitle(_ url: URL, codec: String?, select: Bool) -> Bool { false }

    // Default: keep the rich movie-playback session. Only VLCKit opts out.
    var prefersSpatializedAudioSession: Bool { true }

    // Native external video playback is AVPlayer-only. Engines opt in.
    var supportsExternalPlayback: Bool { false }
    var isExternalPlaybackActive: Bool { false }

    // Picture in Picture is iOS-only and opt-in per engine; tvOS engines and
    // the Metal video-enhancement render path fall back to these no-ops.
    var isPictureInPicturePossible: Bool { false }
    var isPictureInPictureActive: Bool { false }
    func setPictureInPictureDelegate(_ delegate: (any PlaybackPictureInPictureDelegate)?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
}

/// Where locally rendered text subtitles get their look from. System follows
/// Settings › Accessibility › Subtitles & Captioning; Dusk uses its own look
/// (`SystemCaptionStyle.dusk`) whatever the system style is.
enum SubtitleStyle: String, CaseIterable, Identifiable, Sendable {
    case system
    case dusk

    static let `default`: SubtitleStyle = .system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .dusk: "Dusk"
        }
    }
}

/// User-facing subtitle size preference. `medium` is the historical default
/// and reproduces the platform baseline exactly; the other cases scale it.
enum SubtitleFontSize: String, CaseIterable, Identifiable, Sendable {
    case extraSmall
    case small
    case medium
    case large

    static let `default`: SubtitleFontSize = .medium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .extraSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Multiplier applied to the platform baseline in `PlaybackSubtitleStyle`.
    var scale: Float {
        switch self {
        case .extraSmall: 0.6
        case .small: 0.8
        case .medium: 1.0
        case .large: 1.25
        }
    }

    /// Secondary label for the player pickers.
    var detailTitle: String? {
        self == .medium ? "Default" : nil
    }
}

/// The part of the player an overlay covers, measured from the bottom edge, in
/// the player's own points. Each engine turns it into a lift of its subtitles,
/// because only the engine knows where its picture and its cues sit.
struct SubtitleClearance: Equatable, Sendable {
    /// Highest lift, as a fraction of the picture height. Keeps a raised cue on
    /// screen in a very short window.
    static let maximumLift = 0.7

    var containerSize: CGSize
    var coveredHeight: CGFloat
    /// Breathing room between the raised cue and the overlay.
    var spacing: CGFloat
    /// Pixels per point on the player's screen.
    var displayScale: CGFloat

    /// How far to raise cues, as a fraction of the picture height. A
    /// letterboxed picture's cues already sit above its bars, so a cue that
    /// clears the overlay as it is gets a lift of 0 and stays where it was.
    ///
    /// - Parameters:
    ///   - videoSize: the picture's pixel size; zero when it is not known yet.
    ///   - fillsContainer: the iOS zoom control's aspect-fill mode.
    ///   - restingCueBottom: where an unmoved cue's bottom edge sits, as a
    ///     fraction of the picture height above the picture's bottom edge.
    func lift(videoSize: CGSize, fillsContainer: Bool, restingCueBottom: Double) -> Double {
        guard containerSize.width > 0, containerSize.height > 0 else { return 0 }

        let pictureHeight = pictureHeight(videoSize: videoSize, fillsContainer: fillsContainer)
        let pictureBottomInset = (containerSize.height - pictureHeight) / 2
        let target = (coveredHeight + spacing - pictureBottomInset) / pictureHeight
        return min(max(target - restingCueBottom, 0), Self.maximumLift)
    }

    /// The picture's height on screen, in points.
    func pictureHeight(videoSize: CGSize, fillsContainer: Bool) -> CGFloat {
        guard videoSize.width > 0, videoSize.height > 0 else { return containerSize.height }
        let scaleToWidth = containerSize.width / videoSize.width
        let scaleToHeight = containerSize.height / videoSize.height
        return videoSize.height * (fillsContainer ? max(scaleToWidth, scaleToHeight) : min(scaleToWidth, scaleToHeight))
    }
}

/// Steps a subtitle lift towards its target. libvlc cannot animate its subtitle
/// renderer, so this re-applies the position frame by frame.
@MainActor
final class SubtitleLiftAnimator {
    private static let duration: TimeInterval = 0.3
    private static let stepCount = 10

    private(set) var currentLift: Double = 0
    private var task: Task<Void, Never>?

    /// `apply` receives every intermediate lift, and the target last.
    func animate(to target: Double, apply: @escaping @MainActor (Double) -> Void) {
        task?.cancel()
        task = nil

        let start = currentLift
        guard abs(target - start) > 0.0005 else { return }

        task = Task { @MainActor [weak self] in
            let stepDuration = Self.duration / Double(Self.stepCount)
            for step in 1...Self.stepCount {
                let progress = Double(step) / Double(Self.stepCount)
                // Ease in and out, like the poster's own move.
                let eased = progress * progress * (3 - 2 * progress)
                let lift = start + (target - start) * eased
                self?.currentLift = lift
                apply(lift)
                guard step < Self.stepCount else { break }
                try? await Task.sleep(for: .seconds(stepDuration))
                if Task.isCancelled { return }
            }
        }
    }

    /// Back to no lift at once, for a new item: nothing is on screen to move.
    func reset() {
        task?.cancel()
        task = nil
        currentLift = 0
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
enum PlaybackSubtitleStyle {
    /// The Medium baseline, in percent of the renderer's default size.
    static var baseAVPlayerRelativeFontSize: Int {
        #if os(macOS)
        // A desktop window, like iPad's and Mac Catalyst's `.mac` idiom.
        return 75
        #else
        switch userInterfaceIdiom {
        case .pad, .mac:
            return 75
        default:
            return 100
        }
        #endif
    }

    /// `systemScale` is the Accessibility caption text size
    /// (`SystemCaptionStyle.relativeSize`); Dusk's step multiplies onto it.
    static func avPlayerRelativeFontSize(for size: SubtitleFontSize, systemScale: Double = 1) -> Int {
        Int((Float(baseAVPlayerRelativeFontSize) * size.scale * Float(systemScale)).rounded())
    }

    /// libvlc's `freetype-rel-fontsize`: the font height is the video height
    /// divided by this value, so a smaller number draws larger text. 16 is
    /// libvlc's default and maps to 100%.
    static func vlcRelativeFontSize(for size: SubtitleFontSize, systemScale: Double = 1) -> Int {
        let scale = Float(avPlayerRelativeFontSize(for: size, systemScale: systemScale)) / 100
        return max(1, Int((16 / scale).rounded()))
    }

    #if !os(macOS)
    private static var userInterfaceIdiom: UIUserInterfaceIdiom {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom
        #else
        .unspecified
        #endif
    }
    #endif
}
