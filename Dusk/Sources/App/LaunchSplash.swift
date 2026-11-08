import SwiftUI
import UIKit

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
///
/// The motion is played by Core Animation, never by a per-frame SwiftUI update.
/// The exit runs exactly while Home's first paint, focus and artwork keep the
/// main thread busy, so anything drawn from the main thread stutters (#54). The
/// curves are sampled up front and handed to the render server, which keeps
/// going however long the main thread is blocked.
struct LaunchSplashOverlay: View {
    let state: LaunchSplashState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var exitStyle: LaunchSplashExitStyle?
    @State private var isFinished = false

    /// The longest the splash covers a launch that never reports ready.
    private static let patience: Duration = .seconds(10)
    /// The exit reports its own end; this only covers it never being told, as
    /// when the system drops running animations on the way to the background.
    private static let finishFallbackMargin: TimeInterval = 2

    var body: some View {
        if !isFinished {
            LaunchSplashAnimationView(
                exitStyle: exitStyle,
                reduceMotion: reduceMotion,
                onExitFinished: { isFinished = true }
            )
            .ignoresSafeArea()
            .allowsHitTesting(exitStyle == nil)
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

    private func beginExit() {
        guard exitStyle == nil, !isFinished else { return }
        let style = LaunchSplashExitStyle.current(reduceMotion: reduceMotion)
        exitStyle = style
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(style.duration + Self.finishFallbackMargin))
            isFinished = true
        }
    }
}

// MARK: - Layers

private struct LaunchSplashAnimationView: UIViewRepresentable {
    let exitStyle: LaunchSplashExitStyle?
    let reduceMotion: Bool
    let onExitFinished: () -> Void

    func makeUIView(context: Context) -> LaunchSplashUIView {
        LaunchSplashUIView(reduceMotion: reduceMotion)
    }

    func updateUIView(_ view: LaunchSplashUIView, context: Context) {
        view.onExitFinished = onExitFinished
        if let exitStyle {
            view.beginExit(style: exitStyle)
        }
    }
}

private final class LaunchSplashUIView: UIView {
    var onExitFinished: (() -> Void)?

    private let reduceMotion: Bool
    private let backdrop = UIView()
    /// Carries the breathing pulse. The exit plays on `logo` inside it, so the
    /// two multiply: the exit picks up from the logo as the pulse left it.
    private let pulseContainer = UIView()
    private let logo = UIImageView(image: UIImage(named: "LaunchLogo"))
    private var hasStartedPulse = false
    private var hasBegunExit = false

    private static let exitAnimationKey = "launchSplashExit"
    private static let pulseAnimationKey = "launchSplashPulse"

    /// How long a launch may stay still before the logo starts to breathe.
    private static let pulseDelay: TimeInterval = 0.6
    private static let pulsePeriod: TimeInterval = 1.6
    /// Dense enough that the straight segments between samples never show,
    /// even at 120 Hz on the steep end of the fly-through.
    private static let samplesPerSecond = 120.0

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
    private static let zoomAnchor = CGPoint(x: 0.36, y: 0.5)

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)

        backdrop.backgroundColor = UIColor(Color.duskBackground)
        addSubview(backdrop)

        logo.contentMode = .scaleAspectFit
        // The artwork is several times its on-screen size until the zoom
        // catches up with it; without mipmaps its edges shimmer.
        logo.layer.minificationFilter = .trilinear
        pulseContainer.addSubview(logo)
        addSubview(pulseContainer)

        pulseContainer.layer.anchorPoint = Self.zoomAnchor
        logo.layer.anchorPoint = Self.zoomAnchor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds

        // Bounds and position rather than frame: both views carry a transform
        // while animating, and an off-centre anchor.
        let size = Self.logoSize
        let anchorOffset = CGPoint(x: size.width * Self.zoomAnchor.x, y: size.height * Self.zoomAnchor.y)
        pulseContainer.bounds = CGRect(origin: .zero, size: size)
        pulseContainer.layer.position = CGPoint(
            x: bounds.midX - size.width / 2 + anchorOffset.x,
            y: bounds.midY - size.height / 2 + anchorOffset.y
        )
        logo.bounds = CGRect(origin: .zero, size: size)
        logo.layer.position = anchorOffset
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasStartedPulse, !hasBegunExit else { return }
        hasStartedPulse = true
        startPulse()
    }

    func beginExit(style: LaunchSplashExitStyle) {
        guard !hasBegunExit else { return }
        hasBegunExit = true
        freezePulse()

        let end = style.frame(at: 1)
        let values = Self.samples(duration: style.duration) { style.frame(at: $0) }
        let duration = style.duration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            self?.onExitFinished?()
        }
        // The model holds the end state, so nothing snaps back in the moment
        // between the animations ending and the overlay leaving the hierarchy.
        logo.layer.transform = CATransform3DMakeScale(end.logoScale, end.logoScale, 1)
        logo.layer.opacity = Float(end.logoOpacity)
        backdrop.layer.opacity = Float(end.backdropOpacity)

        let scale = Self.keyframes("transform.scale", duration: duration, values: values.map(\.logoScale))
        logo.layer.add(scale, forKey: "\(Self.exitAnimationKey).scale")
        let logoOpacity = Self.keyframes("opacity", duration: duration, values: values.map(\.logoOpacity))
        logo.layer.add(logoOpacity, forKey: "\(Self.exitAnimationKey).opacity")
        let backdropOpacity = Self.keyframes("opacity", duration: duration, values: values.map(\.backdropOpacity))
        backdrop.layer.add(backdropOpacity, forKey: Self.exitAnimationKey)
        CATransaction.commit()
    }

    // MARK: Pulse

    private func startPulse() {
        // A launch that is ready at once never reaches the pulse.
        let count = Int(Self.pulsePeriod * Self.samplesPerSecond)
        let breaths = (0...count).map { index -> Double in
            (1 - cos(2 * .pi * Double(index) / Double(count))) / 2
        }
        let beginTime = CACurrentMediaTime() + Self.pulseDelay

        let opacity = Self.keyframes(
            "opacity",
            duration: Self.pulsePeriod,
            values: breaths.map { 1 - 0.18 * $0 }
        )
        opacity.beginTime = beginTime
        opacity.repeatCount = .infinity
        pulseContainer.layer.add(opacity, forKey: "\(Self.pulseAnimationKey).opacity")

        guard !reduceMotion else { return }
        let scale = Self.keyframes(
            "transform.scale",
            duration: Self.pulsePeriod,
            values: breaths.map { 1 + 0.035 * $0 }
        )
        scale.beginTime = beginTime
        scale.repeatCount = .infinity
        pulseContainer.layer.add(scale, forKey: "\(Self.pulseAnimationKey).scale")
    }

    /// Stops the pulse where it is, so the exit doesn't snap back to rest.
    private func freezePulse() {
        let layer = pulseContainer.layer
        guard let current = layer.presentation() else {
            layer.removeAllAnimations()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = current.transform
        layer.opacity = current.opacity
        layer.removeAllAnimations()
        CATransaction.commit()
    }

    // MARK: Keyframes

    private static func samples(
        duration: TimeInterval,
        _ frame: (Double) -> LaunchSplashFrame
    ) -> [LaunchSplashFrame] {
        let count = max(Int(duration * samplesPerSecond), 1)
        return (0...count).map { frame(Double($0) / Double(count)) }
    }

    private static func keyframes<Value>(
        _ keyPath: String,
        duration: TimeInterval,
        values: [Value]
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        return animation
    }
}

// MARK: - Curves

private struct LaunchSplashFrame {
    var logoScale: CGFloat = 1
    var logoOpacity: Double = 1
    var backdropOpacity: Double = 1
}

private enum LaunchSplashExitStyle: Equatable {
    case flyThrough
    case pushIn
    case crossfade

    static func current(reduceMotion: Bool) -> LaunchSplashExitStyle {
        if reduceMotion { return .crossfade }
        #if os(tvOS)
        return .flyThrough
        #else
        return .pushIn
        #endif
    }

    var duration: TimeInterval {
        switch self {
        case .flyThrough: 1.0
        case .pushIn: 0.7
        case .crossfade: 0.4
        }
    }

    func frame(at p: Double) -> LaunchSplashFrame {
        switch self {
        case .flyThrough:
            // 0–18 %: settle back a touch. Then an accelerating, exponential
            // zoom (constant-feeling growth that keeps speeding up) to far past
            // the screen edges; the backdrop opens in the middle of the flight
            // and the tiles fade only once they are mostly off screen.
            let anticipation = 0.18
            let dip = 0.92
            if p < anticipation {
                let t = easeOut(p / anticipation)
                return LaunchSplashFrame(logoScale: 1 - (1 - dip) * t, logoOpacity: 1, backdropOpacity: 1)
            }
            let q = (p - anticipation) / (1 - anticipation)
            let scale = dip * pow(26 / dip, q * q)
            return LaunchSplashFrame(
                logoScale: scale,
                logoOpacity: 1 - smoothstep(0.62, 1.0, q),
                backdropOpacity: 1 - smoothstep(0.3, 0.85, q)
            )
        case .pushIn:
            let anticipation = 0.2
            let dip = 0.95
            if p < anticipation {
                let t = easeOut(p / anticipation)
                return LaunchSplashFrame(logoScale: 1 - (1 - dip) * t, logoOpacity: 1, backdropOpacity: 1)
            }
            let q = (p - anticipation) / (1 - anticipation)
            return LaunchSplashFrame(
                logoScale: dip * pow(2.6 / dip, easeIn(q)),
                logoOpacity: 1 - smoothstep(0.05, 0.7, q),
                backdropOpacity: 1 - smoothstep(0.2, 1.0, q)
            )
        case .crossfade:
            let fade = 1 - smoothstep(0, 1, p)
            return LaunchSplashFrame(logoScale: 1, logoOpacity: fade, backdropOpacity: fade)
        }
    }

    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private func easeIn(_ t: Double) -> Double { t * t }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
