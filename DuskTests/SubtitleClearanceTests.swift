import CoreGraphics
import Testing
@testable import Dusk

struct SubtitleClearanceTests {
    private func clearance(width: CGFloat, height: CGFloat, covered: CGFloat) -> SubtitleClearance {
        SubtitleClearance(
            containerSize: CGSize(width: width, height: height),
            coveredHeight: covered,
            spacing: 10,
            displayScale: 3
        )
    }

    @Test func raisesFullBleedCueAboveTheOverlay() {
        let lift = clearance(width: 1600, height: 900, covered: 170)
            .lift(videoSize: CGSize(width: 1920, height: 1080), fillsContainer: false, restingCueBottom: 0.05)
        #expect(abs(lift - 0.15) < 0.001)
    }

    @Test func letterboxBarsReduceTheLift() {
        // 2:1 in a 2000x1500 container: picture 1000 tall, bars of 250.
        let lift = clearance(width: 2000, height: 1500, covered: 340)
            .lift(videoSize: CGSize(width: 2000, height: 1000), fillsContainer: false, restingCueBottom: 0.05)
        #expect(abs(lift - 0.05) < 0.001)
    }

    @Test func cueAlreadyAboveTheOverlayStaysPut() {
        let lift = clearance(width: 400, height: 800, covered: 100)
            .lift(videoSize: CGSize(width: 1920, height: 1080), fillsContainer: false, restingCueBottom: 0.05)
        #expect(lift == 0)
    }

    @Test func liftIsCappedInAVeryShortWindow() {
        let lift = clearance(width: 400, height: 100, covered: 200)
            .lift(videoSize: .zero, fillsContainer: false, restingCueBottom: 0.05)
        #expect(lift == SubtitleClearance.maximumLift)
    }

    @Test func noContainerMeansNoLift() {
        let lift = clearance(width: 0, height: 0, covered: 100)
            .lift(videoSize: .zero, fillsContainer: false, restingCueBottom: 0.05)
        #expect(lift == 0)
    }
}
