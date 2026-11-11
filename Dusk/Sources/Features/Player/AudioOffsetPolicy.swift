import Foundation

/// Manual audio sync (#67): what a per-session audio offset may do to the
/// playing session. Pure, so the engine-switch rules are testable without a
/// running engine.
///
/// Only VLCKit can delay audio (`currentAudioPlaybackDelay`). AVPlayer has no
/// such control, so a non-zero offset on an AVPlayer session restarts the item
/// on VLCKit at the current position and the session stays there, even if the
/// offset returns to zero. HDR/Dolby Vision never takes that switch: VLCKit
/// draws SDR only and Dolby Vision 5 turns pink (see a310f05, #59).
enum AudioOffsetPolicy {
    static let stepMilliseconds = 50
    static let range = -2000...2000

    /// Hint under the control when an offset can be applied. Both platforms
    /// show this; an unavailable session replaces it with the reason.
    static let timingDescription =
        "Adjusts audio timing. Positive values delay audio; negative values advance it."

    enum Availability: Equatable {
        case available
        case unavailable(reason: String)

        var isAvailable: Bool { self == .available }

        var unavailableReason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }

        static let hdrVideo = Availability.unavailable(reason: "Not available for HDR video")
        static let airPlay = Availability.unavailable(reason: "Not available during AirPlay")
        static let liveTV = Availability.unavailable(reason: "Not available for live TV")
        static let unsupportedVideo = Availability.unavailable(reason: "Not available for this video")
    }

    enum Action: Equatable {
        /// The engine applies the delay in place.
        case applyLive
        /// Restart the item on VLCKit at the current position with the delay.
        case switchToVLCKit
        /// AVPlayer at zero: nothing to apply and no reason to switch.
        case none
        case blocked(reason: String)
    }

    /// The session facts the decision depends on.
    struct Session: Equatable {
        var engine: PlaybackEngineType
        var decision: PlaybackDecision
        var containsHDRVideo: Bool
        /// VLCKit can decode the video (false for AV1 on a VLCKit build
        /// without the AV1 decoder).
        var vlcKitCanDecodeVideo: Bool = true
    }

    static func clamped(_ milliseconds: Int) -> Int {
        min(max(milliseconds, range.lowerBound), range.upperBound)
    }

    static func availability(for session: Session) -> Availability {
        switch session.decision {
        case .airPlay:
            return .airPlay
        case .liveTV where session.engine != .vlcKit:
            return .liveTV
        default:
            break
        }
        if session.engine == .vlcKit { return .available }
        if session.containsHDRVideo { return .hdrVideo }
        if !session.vlcKitCanDecodeVideo { return .unsupportedVideo }
        return .available
    }

    static func action(settingOffset milliseconds: Int, in session: Session) -> Action {
        if case .unavailable(let reason) = availability(for: session) {
            return .blocked(reason: reason)
        }
        if session.engine == .vlcKit { return .applyLive }
        return milliseconds == 0 ? .none : .switchToVLCKit
    }

    /// The engine a later replacement of the same item (quality switch,
    /// fallback, track rebuild) should use once the offset moved the session
    /// to VLCKit: it stays on VLCKit, except where only AVPlayer can deliver
    /// (AirPlay, live TV) or the video is HDR.
    static func replacementEngine(
        requested: PlaybackEngineType,
        isPinnedToVLCKit: Bool,
        decision: PlaybackDecision,
        containsHDRVideo: Bool
    ) -> PlaybackEngineType {
        guard isPinnedToVLCKit, requested == .avPlayer, !containsHDRVideo else { return requested }
        switch decision {
        case .airPlay, .liveTV:
            return requested
        default:
            return .vlcKit
        }
    }

    /// "0 ms", "+150 ms", "−200 ms" (positive delays the audio).
    static func title(for milliseconds: Int) -> String {
        if milliseconds == 0 { return "0 ms" }
        let sign = milliseconds > 0 ? "+" : "\u{2212}"
        return "\(sign)\(abs(milliseconds)) ms"
    }
}
