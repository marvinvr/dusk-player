#if os(tvOS)
import SwiftUI
import UIKit

enum PlayerTVArrow: Equatable {
    case left
    case right
    case up
    case down
}

/// Everything the Siri Remote can say to the player, normalized into one
/// vocabulary. `PlayerTVHUDController` is the only consumer.
enum PlayerTVRemoteInput: Equatable {
    /// A directional button went down (a click on the ring, or a directional
    /// flick on the touch surface — tvOS reports both as arrow presses).
    case arrowDown(PlayerTVArrow)
    /// The same button came back up. Ends a hold-to-seek.
    case arrowUp(PlayerTVArrow)
    case select
    case playPause
    case menu
    /// A light tap on the touch surface with no click.
    case touchTap
    case panBegan
    /// Cumulative horizontal translation since `panBegan`.
    case panChanged(translationX: CGFloat, velocityX: CGFloat)
    case panEnded
}

/// The player's single remote-input owner.
///
/// There used to be four of these fighting over focus and the first-responder
/// chain (a seek view, a tap bridge, a focusable background and the overlay's
/// own `@FocusState`). This is the replacement: one view controller that is
/// first responder while `isCaptureEnabled`, and nothing else in the tvOS
/// player is focusable except the settings panel — which turns capture off
/// while it is up so the SwiftUI focus engine can own the remote instead.
///
/// Its view is also the player's **focus sentinel**: it is the one focusable
/// item while capture is on. tvOS routes button presses through the focused
/// item's responder chain and delivers touch-surface (indirect) touches to the
/// focused view, so with a HUD that has no focusable controls at all there
/// would otherwise be nothing for either to land on. Being both the focused
/// item and the first responder makes the two routes converge on this
/// controller. It cannot fight anything for focus because it is the only
/// candidate, and a plain `UIView` draws no focus effect.
///
/// Anything this controller does not understand is forwarded to `super` so the
/// system keeps its own behaviours (Siri, volume, the home gesture).
struct PlayerTVRemoteInputBridge: UIViewControllerRepresentable {
    var isCaptureEnabled: Bool
    var onInput: (PlayerTVRemoteInput) -> Void

    func makeUIViewController(context _: Context) -> PlayerTVRemoteInputViewController {
        let controller = PlayerTVRemoteInputViewController()
        controller.onInput = onInput
        controller.isCaptureEnabled = isCaptureEnabled
        return controller
    }

    func updateUIViewController(_ uiViewController: PlayerTVRemoteInputViewController, context _: Context) {
        uiViewController.onInput = onInput
        uiViewController.isCaptureEnabled = isCaptureEnabled
    }
}

final class PlayerTVRemoteInputViewController: UIViewController {
    var onInput: ((PlayerTVRemoteInput) -> Void)?

    var isCaptureEnabled = false {
        didSet {
            guard oldValue != isCaptureEnabled else { return }
            viewIfLoaded?.isUserInteractionEnabled = isCaptureEnabled
            if !isCaptureEnabled {
                // A pan that is still live when capture goes away would leave
                // the controller dropping every arrow press forever.
                endActivePan()
            }
            refreshFirstResponderStatus()
            refreshFocusability()
        }
    }

    private enum PanAxis {
        case undetermined
        case horizontal
        /// A vertical flick. tvOS also delivers it as an up/down arrow press,
        /// which is what opens the panel — so the pan must stay out of it or a
        /// swipe down would start a scrub at the same time.
        case rejected
    }

    private let panRecognizer = UIPanGestureRecognizer()
    private let tapRecognizer = UITapGestureRecognizer()
    private var panAxis: PanAxis = .undetermined
    private var heldArrows: Set<PlayerTVArrow> = []

    override func loadView() {
        view = PlayerTVRemoteInputView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        view.isUserInteractionEnabled = isCaptureEnabled

        let indirect = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]

        panRecognizer.allowedTouchTypes = indirect
        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(panRecognizer)

        // `allowedPressTypes = []` keeps a click from also reading as a tap;
        // `cancelsTouchesInView = false` keeps the pan alive underneath it.
        tapRecognizer.allowedTouchTypes = indirect
        tapRecognizer.allowedPressTypes = []
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tapRecognizer)

        sentinelView?.isFocusable = isCaptureEnabled
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshFirstResponderStatus()
        refreshFocusability()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        endActivePan()
        releaseHeldArrows()
        if isFirstResponder {
            resignFirstResponder()
        }
    }

    override var canBecomeFirstResponder: Bool {
        isCaptureEnabled && viewIfLoaded?.window != nil
    }

    // MARK: - Presses

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCaptureEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }

        var handled = false
        for press in presses {
            guard let input = Self.beganInput(for: press.type) else { continue }
            if case let .arrowDown(arrow) = input {
                heldArrows.insert(arrow)
            }
            handled = true
            onInput?(input)
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCaptureEnabled else {
            super.pressesEnded(presses, with: event)
            return
        }

        var handled = false
        for press in presses {
            if let arrow = Self.arrow(for: press.type) {
                handled = true
                heldArrows.remove(arrow)
                onInput?(.arrowUp(arrow))
            } else if Self.beganInput(for: press.type) != nil {
                // Select / play-pause / menu are acted on at press-down; their
                // release is ours to swallow, not the system's to re-handle.
                handled = true
            }
        }

        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let arrow = Self.arrow(for: press.type), heldArrows.remove(arrow) != nil else { continue }
            onInput?(.arrowUp(arrow))
        }

        super.pressesCancelled(presses, with: event)
    }

    private static func arrow(for type: UIPress.PressType) -> PlayerTVArrow? {
        switch type {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        default: return nil
        }
    }

    private static func beganInput(for type: UIPress.PressType) -> PlayerTVRemoteInput? {
        if let arrow = arrow(for: type) {
            return .arrowDown(arrow)
        }

        switch type {
        case .select: return .select
        case .playPause: return .playPause
        case .menu: return .menu
        default: return nil
        }
    }

    /// A first responder that loses its presses mid-hold (capture turned off,
    /// the view left the window) would otherwise leave the seek accumulator
    /// running forever.
    private func releaseHeldArrows() {
        let arrows = heldArrows
        heldArrows.removeAll()
        for arrow in arrows {
            onInput?(.arrowUp(arrow))
        }
    }

    // MARK: - Gestures

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard isCaptureEnabled, recognizer.state == .ended else { return }
        onInput?(.touchTap)
    }

    @objc
    private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)

        switch recognizer.state {
        case .began:
            guard isCaptureEnabled else { return }
            panAxis = .undetermined
        case .changed:
            guard isCaptureEnabled else { return }
            switch panAxis {
            case .rejected:
                return
            case .undetermined:
                // Direction lock. A vertical flick is the panel gesture and is
                // dropped here; a horizontal one becomes a scrub, but only
                // after it has cleared the deadzone.
                guard max(abs(translation.x), abs(translation.y)) >= PlayerTVHUDLayout.swipeDeadzone else {
                    return
                }
                guard abs(translation.x) > abs(translation.y) else {
                    panAxis = .rejected
                    return
                }
                panAxis = .horizontal
                onInput?(.panBegan)
                onInput?(
                    .panChanged(
                        translationX: translation.x,
                        velocityX: recognizer.velocity(in: recognizer.view).x
                    )
                )
            case .horizontal:
                onInput?(
                    .panChanged(
                        translationX: translation.x,
                        velocityX: recognizer.velocity(in: recognizer.view).x
                    )
                )
            }
        case .ended, .cancelled, .failed:
            // Deliberately outside the capture guard: the controller ignores
            // arrow presses until the pan it believes is live has ended, so
            // this has to be delivered even when capture went away mid-swipe.
            endActivePan()
        default:
            break
        }
    }

    /// Ends an in-flight horizontal pan exactly once. Safe to call when no pan
    /// is running.
    private func endActivePan() {
        let wasHorizontal = panAxis == .horizontal
        panAxis = .undetermined
        guard wasHorizontal else { return }
        onInput?(.panEnded)
    }

    // MARK: - Focus

    private var sentinelView: PlayerTVRemoteInputView? {
        viewIfLoaded as? PlayerTVRemoteInputView
    }

    /// Keeps the focus sentinel in sync with capture: focusable (and focused)
    /// while this controller owns the remote, unfocusable the moment something
    /// that uses the SwiftUI focus engine — the settings panel, a cover — takes
    /// over.
    private func refreshFocusability() {
        guard let sentinelView else { return }
        sentinelView.isFocusable = isCaptureEnabled
        guard sentinelView.window != nil else { return }

        if isCaptureEnabled {
            UIFocusSystem.focusSystem(for: sentinelView)?.requestFocusUpdate(to: sentinelView)
        } else {
            // A no-op unless this controller still contains the focused item —
            // which is precisely the case that has to be moved away from.
            setNeedsFocusUpdate()
        }
        updateFocusIfNeeded()
    }

    // MARK: - First responder

    private func refreshFirstResponderStatus() {
        guard viewIfLoaded?.window != nil else { return }

        if isCaptureEnabled {
            guard !isFirstResponder else { return }
            // Deferred: SwiftUI may still be tearing down whatever held focus
            // (the settings panel, the subtitle search cover), and taking the
            // responder chain back inside that same turn loses the race.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCaptureEnabled, self.viewIfLoaded?.window != nil else { return }
                self.becomeFirstResponder()
            }
        } else {
            releaseHeldArrows()
            if isFirstResponder {
                resignFirstResponder()
            }
        }
    }
}

private final class PlayerTVRemoteInputView: UIView {
    /// Focusable only while the controller is capturing. Nothing is drawn for
    /// it: a plain `UIView` has no focus effect, so the sentinel is invisible.
    var isFocusable = false

    override var canBecomeFocused: Bool {
        isFocusable && isUserInteractionEnabled && window != nil
    }
}
#endif
