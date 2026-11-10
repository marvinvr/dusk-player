import Foundation

/// A Picture in Picture start that has to wait until AVKit can take it.
///
/// `AVPictureInPictureController.startPictureInPicture()` is dropped without
/// any delegate callback while the controller is not possible. A freshly built
/// sample-buffer controller (the VLCKit PiP output) reports possible before its
/// layer shows a frame and then flaps possible / not possible for a moment, so
/// a single start issued on the first "possible" was regularly lost. The
/// request is kept until PiP is active, re-issuing the start while it is
/// startable (spaced so an in-flight start can finish), and gives up at its
/// deadline. Pure value type so the policy is unit-testable without AVKit.
struct PictureInPictureStartRequest: Equatable {
    enum Step: Equatable {
        /// Call `startPictureInPicture()` now.
        case start
        /// Not startable yet (or a start is still in flight); check again.
        case wait
        /// PiP is active; drop the request.
        case done
        /// The deadline passed without PiP starting; drop the request.
        case expired
    }

    /// Minimum gap between two issued starts.
    static let startSpacing: Duration = .milliseconds(700)

    let deadline: ContinuousClock.Instant
    private(set) var attempts = 0
    private var nextStartAllowedAt: ContinuousClock.Instant?

    init(timeout: Duration, now: ContinuousClock.Instant = .now) {
        deadline = now + timeout
    }

    mutating func nextStep(
        now: ContinuousClock.Instant,
        isPossible: Bool,
        hasContent: Bool,
        isActive: Bool
    ) -> Step {
        if isActive { return .done }
        if now >= deadline { return .expired }
        guard isPossible, hasContent else { return .wait }
        if let nextStartAllowedAt, now < nextStartAllowedAt { return .wait }
        attempts += 1
        nextStartAllowedAt = now + Self.startSpacing
        return .start
    }
}
