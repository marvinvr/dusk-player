import Foundation
import Testing
@testable import Dusk

/// The VLCKit sample-buffer PiP output used to issue a single start on the
/// first "possible" report; AVKit dropped it while the fresh controller was
/// still settling (no frame yet, possible flapping) and the button did nothing.
@Suite("Picture in Picture start request")
struct PictureInPictureStartRequestTests {
    private let t0 = ContinuousClock.now

    @Test func waitsUntilPossibleAndShowingAFrame() {
        var request = PictureInPictureStartRequest(timeout: .seconds(8), now: t0)
        #expect(request.nextStep(now: t0, isPossible: false, hasContent: false, isActive: false) == .wait)
        #expect(request.nextStep(now: t0, isPossible: true, hasContent: false, isActive: false) == .wait)
        #expect(request.nextStep(now: t0, isPossible: false, hasContent: true, isActive: false) == .wait)
        #expect(request.attempts == 0)
        #expect(request.nextStep(now: t0, isPossible: true, hasContent: true, isActive: false) == .start)
        #expect(request.attempts == 1)
    }

    @Test func retriesADroppedStartAfterTheSpacing() {
        var request = PictureInPictureStartRequest(timeout: .seconds(8), now: t0)
        #expect(request.nextStep(now: t0, isPossible: true, hasContent: true, isActive: false) == .start)
        // AVKit refused or ignored it: no immediate re-issue while it may still be in flight.
        let soon = t0 + .milliseconds(200)
        #expect(request.nextStep(now: soon, isPossible: true, hasContent: true, isActive: false) == .wait)
        let later = t0 + PictureInPictureStartRequest.startSpacing
        #expect(request.nextStep(now: later, isPossible: true, hasContent: true, isActive: false) == .start)
        #expect(request.attempts == 2)
    }

    @Test func possibleBeforeTheFirstFrameDoesNotConsumeTheRequest() {
        // A fresh controller flaps possible / not possible before the layer
        // has a picture; the request must survive that and start afterwards.
        var request = PictureInPictureStartRequest(timeout: .seconds(8), now: t0)
        for step in 0..<10 {
            let now = t0 + .milliseconds(step * 20)
            let step = request.nextStep(now: now, isPossible: step.isMultiple(of: 2), hasContent: false, isActive: false)
            #expect(step == .wait)
        }
        #expect(request.attempts == 0)
        #expect(request.nextStep(now: t0 + .seconds(1), isPossible: true, hasContent: true, isActive: false) == .start)
    }

    @Test func endsOnceActive() {
        var request = PictureInPictureStartRequest(timeout: .seconds(8), now: t0)
        _ = request.nextStep(now: t0, isPossible: true, hasContent: true, isActive: false)
        #expect(request.nextStep(now: t0 + .seconds(1), isPossible: true, hasContent: true, isActive: true) == .done)
    }

    @Test func expiresAtTheDeadline() {
        var request = PictureInPictureStartRequest(timeout: .seconds(2), now: t0)
        #expect(request.nextStep(now: t0 + .seconds(1), isPossible: false, hasContent: true, isActive: false) == .wait)
        #expect(request.nextStep(now: t0 + .seconds(2), isPossible: true, hasContent: true, isActive: false) == .expired)
    }
}
