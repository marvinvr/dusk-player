import Foundation
import Testing
@testable import Dusk

/// The resume-from-pause refill seek in `VLCKitEngine.playLocally()`. A seek
/// committed while paused and immediately resumed (the tvOS scrub commit) must
/// land on the chosen target, not on libvlc's not-yet-updated clock.
@MainActor
struct VLCKitPausedResumeSeekTests {
    @Test func pendingSeekTargetWinsOverStaleObservedClock() {
        let position = VLCKitEngine.pausedResumePosition(
            pendingSeekTarget: 255.8,
            observedTime: 201.8,
            currentTime: 255.8
        )
        #expect(position == 255.8)
    }

    @Test func pendingSeekBackToStartIsKept() {
        let position = VLCKitEngine.pausedResumePosition(
            pendingSeekTarget: 0,
            observedTime: 312,
            currentTime: 0
        )
        #expect(position == 0)
    }

    @Test func plainResumeRefillsAtObservedClock() {
        let position = VLCKitEngine.pausedResumePosition(
            pendingSeekTarget: nil,
            observedTime: 201.8,
            currentTime: 201.5
        )
        #expect(position == 201.8)
    }

    @Test func plainResumeFallsBackToCurrentTimeWithoutAClock() {
        let position = VLCKitEngine.pausedResumePosition(
            pendingSeekTarget: nil,
            observedTime: 0,
            currentTime: 42
        )
        #expect(position == 42)
    }
}
