#if os(tvOS)
import SwiftUI

/// Geometry, timing and gesture tunables for the tvOS play bar.
///
/// **Everything in here is a first pass and needs an on-device tuning session.**
/// The values were chosen against the tvOS simulator, where the "touch surface"
/// is a trackpad and every click is a key press. The ones most likely to feel
/// wrong on a real Apple TV with a real Siri Remote are called out inline:
/// `swipeSlowGain` / `swipeFastGain`, `swipeDeadzone`,
/// `seekHoldInitialDelay` / `seekHoldRepeatInterval` / `seekHoldRampMultipliers`
/// and `autoHideDelay`.
enum PlayerTVHUDLayout {

    // MARK: - Layout

    /// Side gutter for the whole bottom HUD. tvOS overscan-safe area is ~60pt.
    static let horizontalInset: CGFloat = 60
    /// Distance from the bottom of the screen to the time readout row.
    static let bottomInset: CGFloat = 48

    /// Height of the capsule track itself.
    static let barHeight: CGFloat = 8
    /// The row the bar and its scrub head live in. Tall enough that the grown
    /// head and its stem are never clipped.
    static let barRowHeight: CGFloat = 44
    /// Resting playhead diameter.
    static let headDiameter: CGFloat = 20
    /// Playhead diameter while scrubbing.
    static let scrubbingHeadDiameter: CGFloat = 28
    /// Vertical stem drawn through the bar under the head while scrubbing.
    static let scrubStemWidth: CGFloat = 2
    static let scrubStemHeight: CGFloat = 40

    /// Gap between the bar row and the elapsed / remaining readouts.
    static let barLabelSpacing: CGFloat = 6
    /// Gap between the title / action row and the bar row.
    static let titleBottomSpacing: CGFloat = 20
    /// Gap between two action-row buttons.
    static let actionRowSpacing: CGFloat = 18
    /// Diameter of a circular action-row button.
    static let actionButtonDiameter: CGFloat = 62

    /// Height of the bottom scrim behind the HUD.
    static let backdropHeight: CGFloat = 320

    // MARK: - Bottom-trailing overlays

    // The Skip Intro chip and the Up Next card sit where AVKit puts its
    // contextual actions: trailing-aligned with the bar, resting at the
    // title-safe bottom margin while the HUD is hidden and riding just above
    // the action row while it is up.

    /// Line height of the `metadata` elapsed / remaining readouts under the bar.
    static let readoutRowHeight: CGFloat = 30
    /// Gap between the top of the action row and an overlay riding above it.
    static let bottomTrailingOverlayGap: CGFloat = 24
    /// Bottom inset of a bottom-trailing overlay while the HUD is up.
    static let bottomTrailingRaisedInset: CGFloat = bottomInset
        + readoutRowHeight
        + barLabelSpacing
        + barRowHeight
        + titleBottomSpacing
        + actionButtonDiameter
        + bottomTrailingOverlayGap
    /// Bottom inset of a bottom-trailing overlay while the HUD is hidden: the
    /// tvOS title-safe bottom margin.
    static let bottomTrailingRestingInset: CGFloat = 60
    /// Scale of the chip / card while it owns Select. Matches the app's tvOS
    /// focus scale.
    static let bottomTrailingSelectedScale: CGFloat = 1.05

    /// Skip chip: same height as the circular action buttons, so every control
    /// in the bottom-trailing corner shares one size.
    static let skipChipHeight: CGFloat = actionButtonDiameter
    static let skipChipHorizontalPadding: CGFloat = 36
    static let skipChipMinWidth: CGFloat = 220

    // MARK: - Panel

    /// Fraction of the screen height the settings sheet occupies.
    static let panelHeightFraction: CGFloat = 0.62
    static let panelCornerRadius: CGFloat = 28
    static let panelHorizontalPadding: CGFloat = 44
    static let panelRowCornerRadius: CGFloat = 14
    static let panelRowSpacing: CGFloat = 8

    // MARK: - Timing

    /// How long the transport rests before it hides itself. Armed in the
    /// `transport` mode only — including while paused, which is what tvOS
    /// viewers expect from AVPlayerViewController.
    static let autoHideDelay: TimeInterval = 4.5

    /// A light touch tap arriving this soon after a click is the same physical
    /// press reaching us twice; the second one is dropped.
    static let selectTapDebounce: TimeInterval = 0.35

    /// How long a transient badge (±seek, play/pause) stays up over the video
    /// while the HUD is hidden.
    static let transientBadgeDuration: Duration = .milliseconds(650)

    // MARK: - Hold-to-seek

    /// Delay before a held left/right click starts repeating.
    static let seekHoldInitialDelay: Duration = .milliseconds(550)
    /// Interval between repeats once the hold has started.
    static let seekHoldRepeatInterval: Duration = .milliseconds(160)
    /// Multipliers applied to the user's configured skip interval as the hold
    /// runs on. The last entry repeats forever.
    static let seekHoldRampMultipliers: [Double] = [1, 1, 1, 3, 3, 6, 6, 12]
    /// Grace period after the button comes up before the accumulated offset is
    /// committed, so repeated clicks land as one engine seek instead of many.
    static let seekCommitDebounce: Duration = .milliseconds(260)

    // MARK: - Swipe scrubbing

    /// Fraction of the timeline one point of touch travel moves the cursor at
    /// or below `swipeSlowVelocity`. An edge-to-edge drag on the Siri Remote is
    /// roughly 1000pt of translation, so this is ~3% of the timeline per drag.
    /// Smaller = slower, more precise scrubbing.
    static let swipeSlowGain: Double = 0.00003
    /// Same, at or above `swipeFastVelocity`: ~25% of the timeline per flick.
    static let swipeFastGain: Double = 0.00025
    /// Finger speeds, in points per second, the gain is interpolated between.
    static let swipeSlowVelocity: Double = 400
    static let swipeFastVelocity: Double = 3000
    /// Horizontal travel required before a pan counts as a scrub at all.
    static let swipeDeadzone: CGFloat = 6

    // MARK: - Animation

    static let modeTransition: Animation = .easeInOut(duration: 0.22)
    static let headGrowAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.82)
    static let panelTransition: Animation = .spring(response: 0.36, dampingFraction: 0.9)
    static let selectionAnimation: Animation = .easeOut(duration: 0.18)
    /// How the bottom-trailing overlays rise above / settle below the HUD.
    static let bottomTrailingRepositionAnimation: Animation = .smooth(duration: 0.3)

    /// Respects Reduce Motion the way the rest of the app does (see
    /// `HomeCinematicHero`): the state change still happens, it just stops
    /// being animated.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
#endif
