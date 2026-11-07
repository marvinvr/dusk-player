import Foundation
import Testing
@testable import Dusk

/// A source's off-air slate ends with EXT-X-ENDLIST when the live session
/// starts; the player re-requests the channel instead of closing.
@Suite("IPTV retune policy")
struct IPTVRetunePolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func backoffDoublesFromTwoSecondsAndCapsAtThirty() {
        var policy = IPTVRetunePolicy()
        var delays: [TimeInterval] = []
        var now = start
        for _ in 0..<7 {
            guard case .retune(let delay) = policy.interrupted(at: now) else {
                Issue.record("gave up too early")
                return
            }
            delays.append(delay)
            now = now.addingTimeInterval(delay)
        }
        #expect(delays == [2, 4, 8, 16, 30, 30, 30])
    }

    @Test func givesUpOnlyAfterTwoMinutesOfFailing() {
        var policy = IPTVRetunePolicy()
        #expect(policy.interrupted(at: start) == .retune(after: 2))
        #expect(policy.interrupted(at: start.addingTimeInterval(119)) != .giveUp)
        #expect(policy.interrupted(at: start.addingTimeInterval(120)) != .giveUp)
        #expect(policy.interrupted(at: start.addingTimeInterval(121)) == .giveUp)
    }

    @Test func steadyPlaybackResetsTheBackoff() {
        var policy = IPTVRetunePolicy()
        _ = policy.interrupted(at: start)
        _ = policy.interrupted(at: start.addingTimeInterval(2))
        // The slate (or the live stream) then plays for a while…
        let playing = start.addingTimeInterval(10)
        for second in stride(from: 0.0, through: IPTVRetunePolicy.stablePlayback, by: 0.5) {
            policy.playing(at: playing.addingTimeInterval(second))
        }
        #expect(policy.attempts == 0)
        #expect(policy.interruptedSince == nil)
        // …so the ENDLIST hours later retunes at 2 s again, and the two-minute
        // clock starts fresh.
        let later = start.addingTimeInterval(3600)
        #expect(policy.interrupted(at: later) == .retune(after: 2))
        #expect(policy.interrupted(at: later.addingTimeInterval(121)) == .giveUp)
    }

    @Test func briefPlaybackBetweenFailuresDoesNotReset() {
        var policy = IPTVRetunePolicy()
        _ = policy.interrupted(at: start)
        policy.playing(at: start.addingTimeInterval(3))
        policy.playing(at: start.addingTimeInterval(5))
        #expect(policy.interrupted(at: start.addingTimeInterval(6)) == .retune(after: 4))
        // Pausing restarts the steady-playback clock.
        policy.playing(at: start.addingTimeInterval(10))
        policy.notPlaying()
        policy.playing(at: start.addingTimeInterval(19))
        policy.playing(at: start.addingTimeInterval(25))
        #expect(policy.attempts == 2)
        // A stream that keeps flapping still gives up after two minutes.
        #expect(policy.interrupted(at: start.addingTimeInterval(130)) == .giveUp)
    }

    @Test func networkAndHTTPFailuresAreRetried() {
        #expect(IPTVRetunePolicy.isRetryable(URLError(.networkConnectionLost)))
        #expect(IPTVRetunePolicy.isRetryable(URLError(.cannotConnectToHost)))
        #expect(!IPTVRetunePolicy.isRetryable(URLError(.cancelled)))

        let http404 = NSError(domain: "CoreMediaErrorDomain", code: -12_938)
        let wrapped = NSError(
            domain: AVFoundationErrorDomainName,
            code: -11_850,
            userInfo: [NSUnderlyingErrorKey: http404]
        )
        #expect(IPTVRetunePolicy.isRetryable(wrapped))
        let described = NSError(
            domain: "CoreMediaErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 503: Service Unavailable"]
        )
        #expect(IPTVRetunePolicy.isRetryable(described))
    }

    @Test func decodeAndPolicyFailuresAreNot() {
        #expect(!IPTVRetunePolicy.isRetryable(nil))
        #expect(!IPTVRetunePolicy.isRetryable(NSError(domain: AVFoundationErrorDomainName, code: -11_828)))
        #expect(!IPTVRetunePolicy.isRetryable(FairPlayError.missingLicenseURL))
        #expect(!IPTVRetunePolicy.isRetryable(FairPlayError.unsupportedKeySystem("com.widevine.alpha")))
        #expect(!IPTVRetunePolicy.isRetryable(FairPlayError.licenseRequestFailed(status: 403)))
    }

    @Test func licenseServerOutagesAreRetried() {
        #expect(IPTVRetunePolicy.isRetryable(FairPlayError.licenseRequestFailed(status: nil)))
        #expect(IPTVRetunePolicy.isRetryable(FairPlayError.licenseRequestFailed(status: 502)))
        #expect(IPTVRetunePolicy.isRetryable(FairPlayError.certificateRequestFailed(status: 500)))
    }

    private let AVFoundationErrorDomainName = "AVFoundationErrorDomain"
}
