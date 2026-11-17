import Foundation
import Testing
@testable import Dusk

/// libvlc's caching must cover the audio route's output latency, otherwise a
/// HomePod/AirPlay route garbles LAN playback while remote (1.5 s) plays fine.
struct VLCCachingPolicyTests {
    @Test func wiredRouteKeepsTheLocalityTiers() {
        #expect(PlaybackBufferPolicy.vlcCachingMilliseconds(for: .localFile, outputLatency: 0, isWirelessRoute: false) == 300)
        #expect(PlaybackBufferPolicy.vlcCachingMilliseconds(for: .localNetwork, outputLatency: 0.02, isWirelessRoute: false) == 600)
        #expect(PlaybackBufferPolicy.vlcCachingMilliseconds(for: .remoteNetwork, outputLatency: 0.02, isWirelessRoute: false) == 1_500)
    }

    @Test func unknownLatencyKeepsTheTier() {
        #expect(PlaybackBufferPolicy.vlcCachingMilliseconds(for: .localNetwork, outputLatency: 0, isWirelessRoute: false) == 600)
    }

    @Test func wirelessRouteGetsTheRemoteTier() {
        #expect(PlaybackBufferPolicy.vlcCachingMilliseconds(for: .localNetwork, outputLatency: 0, isWirelessRoute: true) == 1_500)
        #expect(PlaybackBufferPolicy.vlcCachingMilliseconds(for: .localFile, outputLatency: 0.3, isWirelessRoute: true) == 1_500)
    }

    @Test func highLatencyRaisesTheTierUpToLibVLCsCap() {
        #expect(PlaybackBufferPolicy.vlcCachingMilliseconds(for: .localNetwork, outputLatency: 0.4, isWirelessRoute: false) == 700)
        // libvlc caps the device latency it accounts for at 1 s.
        #expect(PlaybackBufferPolicy.vlcCachingMilliseconds(for: .localNetwork, outputLatency: 2.0, isWirelessRoute: false) == 1_300)
    }
}
