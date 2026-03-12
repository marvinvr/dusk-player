import Foundation

/// Creates the correct `PlaybackEngine` for a given media item.
///
/// Usage:
/// ```swift
/// let details: PlexMediaDetails = ...
/// let media = details.media[0]
/// let engine = PlaybackEngineFactory.makeEngine(for: media)
/// ```
@MainActor
enum PlaybackEngineFactory {
    #if canImport(AVFoundation)
    private static var warmedAVPlayerEngine: AVPlayerEngine?
    #endif

    #if canImport(MobileVLCKit)
    private static var warmedVLCKitEngine: VLCKitEngine?
    #endif

    /// Front-load one-time player setup so first playback does not pay the
    /// initialization cost while the user is waiting for video to start.
    static func prewarmIfNeeded() {
        #if canImport(AVFoundation)
        if warmedAVPlayerEngine == nil {
            warmedAVPlayerEngine = AVPlayerEngine()
        }
        #endif

        #if canImport(MobileVLCKit)
        if warmedVLCKitEngine == nil {
            warmedVLCKitEngine = VLCKitEngine()
        }
        #endif
    }

    /// Build a playback engine for the given media.
    ///
    /// - Parameters:
    ///   - media: The Plex media version to play.
    ///   - forceAVPlayer: User preference override to always use AVPlayer.
    ///   - forceVLCKit: User preference override to always use VLCKit.
    /// - Returns: A configured `PlaybackEngine` ready for `load(url:startPosition:)`.
    static func makeEngine(
        for media: PlexMedia,
        forceAVPlayer: Bool = false,
        forceVLCKit: Bool = false
    ) -> any PlaybackEngine {
        let engineType = StreamResolver.resolve(
            media: media,
            forceAVPlayer: forceAVPlayer,
            forceVLCKit: forceVLCKit
        )

        switch engineType {
        case .avPlayer:
            #if canImport(AVFoundation)
            if let warmedAVPlayerEngine {
                self.warmedAVPlayerEngine = nil
                return warmedAVPlayerEngine
            }
            return AVPlayerEngine()
            #else
            fatalError("AVPlayer is not available on this platform")
            #endif
        case .vlcKit:
            #if canImport(MobileVLCKit)
            if let warmedVLCKitEngine {
                self.warmedVLCKitEngine = nil
                return warmedVLCKitEngine
            }
            return VLCKitEngine()
            #elseif canImport(TVVLCKit)
            return VLCKitEngine()
            #else
            fatalError("VLCKit is not available on this platform")
            #endif
        }
    }
}
