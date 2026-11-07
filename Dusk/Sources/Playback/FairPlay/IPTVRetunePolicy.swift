import Foundation

/// When an IPTV channel's stream ends or drops, the player quietly asks for
/// the same channel URL again instead of closing or showing an error.
///
/// The case it exists for: a source serves a looping "slate" while a channel
/// is off air and ends it with `EXT-X-ENDLIST` the moment the live session
/// starts, so a viewer can tune in early and leave it running. The same
/// re-request also rides out a relay restart or a network blip.
///
/// Backoff 2 s → 4 → 8 → 16 → 30 s (capped). Playback that has run steadily
/// for `stablePlayback` resets it. Only after the channel has been failing
/// for more than `giveUpAfter` with no steady playback in between does the
/// player show its error (with Retry).
struct IPTVRetunePolicy: Equatable {
    static let initialDelay: TimeInterval = 2
    static let maximumDelay: TimeInterval = 30
    static let giveUpAfter: TimeInterval = 120
    static let stablePlayback: TimeInterval = 10

    enum Decision: Equatable {
        case retune(after: TimeInterval)
        case giveUp
    }

    private(set) var interruptedSince: Date?
    private(set) var attempts = 0
    private var playingSince: Date?

    /// The stream ended (`EXT-X-ENDLIST` reached) or failed in a way a fresh
    /// request can fix.
    mutating func interrupted(at now: Date) -> Decision {
        playingSince = nil
        let since = interruptedSince ?? now
        interruptedSince = since
        if now.timeIntervalSince(since) > Self.giveUpAfter {
            return .giveUp
        }
        let delay = min(Self.initialDelay * pow(2, Double(attempts)), Self.maximumDelay)
        attempts += 1
        return .retune(after: delay)
    }

    /// Called while the item is actually playing. Once it has played for
    /// `stablePlayback` without interruption the channel counts as healthy
    /// again: a slate that loops for an hour and then ends starts over at 2 s.
    mutating func playing(at now: Date) {
        let since = playingSince ?? now
        playingSince = since
        if now.timeIntervalSince(since) >= Self.stablePlayback {
            interruptedSince = nil
            attempts = 0
        }
    }

    /// Not playing (paused, buffering): steady playback has to start over.
    mutating func notPlaying() {
        playingSince = nil
    }

    mutating func reset() {
        self = IPTVRetunePolicy()
    }

    // MARK: - Which failures a re-request can fix

    /// Network and HTTP failures — a relay restarting, a 404 between the
    /// slate and the live playlist, a dropped connection — and FairPlay
    /// license/certificate requests that failed without an answer or with a
    /// server error. A refused license (4xx), an unsupported key system or a
    /// stream AVPlayer cannot decode fail at once: asking again cannot help.
    static func isRetryable(_ error: Error?) -> Bool {
        guard let error else { return false }
        if let fairPlay = error as? FairPlayError {
            switch fairPlay {
            case .licenseRequestFailed(let status), .certificateRequestFailed(let status):
                return status.map { $0 >= 500 } ?? true
            default:
                return false
            }
        }
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSURLErrorDomain {
                return nsError.code != NSURLErrorCancelled
            }
            if nsError.domain == "CoreMediaErrorDomain", networkCoreMediaCodes.contains(nsError.code) {
                return true
            }
            let description = nsError.localizedDescription.uppercased()
            if description.contains("HTTP ") || description.contains("HTTP/") {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// CoreMedia's HLS loading failures: HTTP 4xx/5xx on playlists and
    /// segments, unreachable or unresponsive playlists, stale live playlists.
    static let networkCoreMediaCodes: Set<Int> = [
        -12_938, // HTTP 404
        -12_660, // HTTP 403
        -12_661, // HTTP 5xx / other HTTP status
        -12_663, // HTTP error
        -12_666, // unrecognized HTTP response
        -12_884, // playlist parse/response error on reload
        -12_885, // no response for segment
        -12_886, // playlist didn't update
        -12_888, // playlist unchanged for too long
        -12_889, // no response for map/playlist
        -12_971, // network timeout
        -16_839, // network unavailable
    ]
}
