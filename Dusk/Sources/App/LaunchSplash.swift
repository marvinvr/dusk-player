import SwiftUI

/// Whether the screen under the launch splash has something worth revealing.
///
/// The splash only exists on a cold launch. `ContentView` reports the screens
/// that are ready the moment they mount (sign-in, the profile picker, a Home
/// bootstrap error); `HomeView` reports its first paint, or the empty, error or
/// outage state that replaces it. Whoever reports first wins; later reports
/// (a profile switch remounting Home) are no-ops.
@MainActor
@Observable
final class LaunchSplashState {
    private(set) var isContentReady = false

    func contentIsReady() {
        guard !isContentReady else { return }
        isContentReady = true
    }
}

/// The cold-launch brand moment: the launch storyboard's logo, carried over
/// pixel for pixel, that leaves as soon as the app underneath is ready.
///
/// - **tvOS**: a short anticipation, then the logo flies at the camera through
///   the hollow of its play triangle, the tiles sweeping past the screen edges
///   while the backdrop opens onto Home.
/// - **iOS / iPadOS**: the same idea, smaller and calmer — a soft push in while
///   logo and backdrop fade.
/// - **Reduce Motion**: a plain crossfade, and the hold pulse is opacity only.
///
/// Nothing is held back for the animation's sake: the exit starts the moment the
/// content is ready and the overlay stops taking touches as it does, so a fast
/// launch only costs the exit itself. A slow launch keeps the logo on screen
/// with a quiet breathing pulse instead of a spinner, up to `patience`, after
/// which the splash leaves anyway and the screen's own loading state shows.
struct LaunchSplashOverlay: View {
    let state: LaunchSplashState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var exitStartedAt: Date?
    @State private var isFinished = false

    /// How long a launch may stay still before the logo starts to breathe.
    private static let pulseDelay: TimeInterval = 0.6
    private static let pulsePeriod: TimeInterval = 1.6
    /// The longest the splash covers a launch that never reports ready.
    private static let patience: Duration = .seconds(10)

    var body: some View {
        if !isFinished {
            TimelineView(.animation) { context in
                canvas(frame: frame(at: context.date))
            }
            .ignoresSafeArea()
            .allowsHitTesting(exitStartedAt == nil)
            .accessibilityHidden(true)
            .onChange(of: state.isContentReady, initial: true) { _, isReady in
                if isReady { beginExit() }
            }
            .task {
                try? await Task.sleep(for: Self.patience)
                beginExit()
            }
        }
    }

    // MARK: - Drawing

    private struct Frame {
        var logoScale: CGFloat = 1
        var logoOpacity: Double = 1
        var backdropOpacity: Double = 1
    }

    private func canvas(frame: Frame) -> some View {
        ZStack {
            Color.duskBackground
                .opacity(frame.backdropOpacity)

            Image("LaunchLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.logoSize.width, height: Self.logoSize.height)
                .scaleEffect(frame.logoScale, anchor: Self.zoomAnchor)
                .opacity(frame.logoOpacity)
        }
    }

    /// Matches the launch storyboards exactly, so the handoff from the system
    /// launch screen is invisible.
    private static var logoSize: CGSize {
        #if os(tvOS)
        CGSize(width: 300, height: 346)
        #else
        CGSize(width: 140, height: 140 * 1130 / 980)
        #endif
    }

    /// The middle of the hollow inside the play triangle (the artwork is
    /// 980 × 1130, the hollow centres around x 355). Zooming here flies through
    /// the opening instead of into a tile.
    private static let zoomAnchor = UnitPoint(x: 0.36, y: 0.5)

    // MARK: - Timing

    private enum ExitStyle {
        case flyThrough
        case pushIn
        case crossfade

        var duration: TimeInterval {
            switch self {
            case .flyThrough: 1.0
            case .pushIn: 0.7
            case .crossfade: 0.4
            }
        }
    }

    private var exitStyle: ExitStyle {
        if reduceMotion { return .crossfade }
        #if os(tvOS)
        return .flyThrough
        #else
        return .pushIn
        #endif
    }

    private func beginExit() {
        guard exitStartedAt == nil, !isFinished else { return }
        let now = Date()
        exitStartedAt = now
        let duration = exitStyle.duration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            isFinished = true
        }
    }

    private func frame(at date: Date) -> Frame {
        var frame = Frame()

        // The pulse freezes where it is once the exit starts, so the exit
        // picks up from the logo as it is rather than snapping back.
        let pulseClock = min(date, exitStartedAt ?? date)
        let pulseTime = pulseClock.timeIntervalSince(startedAt) - Self.pulseDelay
        if pulseTime > 0 {
            let breath = (1 - cos(2 * .pi * pulseTime / Self.pulsePeriod)) / 2
            frame.logoOpacity = 1 - 0.18 * breath
            if !reduceMotion {
                frame.logoScale = 1 + 0.035 * breath
            }
        }

        guard let exitStartedAt else { return frame }
        let style = exitStyle
        let progress = min(max(date.timeIntervalSince(exitStartedAt) / style.duration, 0), 1)
        let exit = Self.exitFrame(style: style, progress: progress)
        frame.logoScale *= exit.logoScale
        frame.logoOpacity *= exit.logoOpacity
        frame.backdropOpacity = exit.backdropOpacity
        return frame
    }

    private static func exitFrame(style: ExitStyle, progress p: Double) -> Frame {
        switch style {
        case .flyThrough:
            // 0–18 %: settle back a touch. Then an accelerating, exponential
            // zoom (constant-feeling growth that keeps speeding up) to far past
            // the screen edges; the backdrop opens in the middle of the flight
            // and the tiles fade only once they are mostly off screen.
            let anticipation = 0.18
            let dip = 0.92
            if p < anticipation {
                let t = easeOut(p / anticipation)
                return Frame(logoScale: 1 - (1 - dip) * t, logoOpacity: 1, backdropOpacity: 1)
            }
            let q = (p - anticipation) / (1 - anticipation)
            let scale = dip * pow(26 / dip, q * q)
            return Frame(
                logoScale: scale,
                logoOpacity: 1 - smoothstep(0.62, 1.0, q),
                backdropOpacity: 1 - smoothstep(0.3, 0.85, q)
            )
        case .pushIn:
            let anticipation = 0.2
            let dip = 0.95
            if p < anticipation {
                let t = easeOut(p / anticipation)
                return Frame(logoScale: 1 - (1 - dip) * t, logoOpacity: 1, backdropOpacity: 1)
            }
            let q = (p - anticipation) / (1 - anticipation)
            return Frame(
                logoScale: dip * pow(2.6 / dip, easeIn(q)),
                logoOpacity: 1 - smoothstep(0.05, 0.7, q),
                backdropOpacity: 1 - smoothstep(0.2, 1.0, q)
            )
        case .crossfade:
            let fade = 1 - smoothstep(0, 1, p)
            return Frame(logoScale: 1, logoOpacity: fade, backdropOpacity: fade)
        }
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func easeIn(_ t: Double) -> Double { t * t }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
