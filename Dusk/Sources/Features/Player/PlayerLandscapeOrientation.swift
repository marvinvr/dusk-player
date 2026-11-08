#if os(iOS)
import CoreMotion
import ObjectiveC
import SwiftUI
import UIKit

/// App-level mask while an iPhone player is on screen.
///
/// `UIViewController.supportedInterfaceOrientations` falls through to
/// `application(_:supportedInterfaceOrientationsFor:)` when a controller does
/// not override it. The player's hosting controller is also given its own
/// override while forcing landscape; both have to allow landscape or
/// `requestGeometryUpdate` is rejected.
enum PlayerOrientationApplicationMask {
    nonisolated(unsafe) static var player: UIInterfaceOrientationMask?
}

/// Which orientations the app allows.
///
/// A plain iPhone keeps its navigation UI in portrait, and only the player
/// cover opens up landscape while it is on screen. iPad and the iPhone Duo
/// layout rotate freely. Info-iOS.plist still lists landscape for iPhone
/// because the Duo needs it; this mask is what narrows a plain iPhone.
enum AppOrientationPolicy {
    static func mask(
        isPad: Bool,
        isDuo: Bool,
        playerMask: UIInterfaceOrientationMask?
    ) -> UIInterfaceOrientationMask {
        if let playerMask { return playerMask }
        if isPad { return .all }
        if isDuo { return .allButUpsideDown }
        return .portrait
    }

    /// Orientation to return to when the player closes. A plain iPhone always
    /// lands in portrait. Elsewhere the interface goes back to where it was.
    static func maskAfterPlayer(
        isPlainPhone: Bool,
        previous: UIInterfaceOrientationMask?
    ) -> UIInterfaceOrientationMask {
        isPlainPhone ? .portrait : (previous ?? .portrait)
    }

    /// iPhone that is not showing the Duo layout.
    @MainActor static var isPlainPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !DuskDuoDisplay.isActive
    }
}

/// One landscape side of the interface. Device landscape and interface
/// landscape are swapped: `UIDeviceOrientation.landscapeLeft` (home button on
/// the right) is `UIInterfaceOrientation.landscapeRight`.
enum PlayerLandscapeSide: Equatable {
    case left
    case right

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .left: .landscapeLeft
        case .right: .landscapeRight
        }
    }

    /// Interface side for a physical `UIDevice` orientation, or nil when the
    /// reading is portrait, flat, or unknown. Those must not leave landscape.
    static func interfaceSide(deviceOrientation: UIDeviceOrientation) -> PlayerLandscapeSide? {
        switch deviceOrientation {
        case .landscapeLeft: .right
        case .landscapeRight: .left
        default: nil
        }
    }

    /// Interface side from CoreMotion gravity in the device frame.
    ///
    /// +x is the right edge, +y is the top, +z is out of the screen. At rest
    /// the vector points at the ground: +x means the right edge is down
    /// (`UIDeviceOrientation.landscapeRight`, interface `.landscapeLeft`).
    /// Portrait Orientation Lock does not affect this reading. Returns nil
    /// unless the phone is clearly on its side, so a portrait or flat hold
    /// does not flip the picture.
    static func interfaceSide(gravityX: Double, y: Double, z: Double) -> PlayerLandscapeSide? {
        let absX = abs(gravityX)
        guard absX > 0.5, absX > abs(y), absX > abs(z) else { return nil }
        return gravityX > 0 ? .left : .right
    }
}

enum PlayerLandscapePolicy {
    /// iPhone only. iPad already rotates with the system, and the setting does
    /// not change that.
    static func shouldForce(isPhone: Bool, alwaysPlayInLandscape: Bool) -> Bool {
        isPhone && alwaysPlayInLandscape
    }

    /// Side to request. CoreMotion wins over `UIDevice` because the orientation
    /// lock freezes `UIDevice` on portrait. A reading that is not landscape
    /// keeps `current`, or `.right` when the player has just opened.
    static func side(
        deviceOrientation: UIDeviceOrientation,
        gravityX: Double?,
        gravityY: Double?,
        gravityZ: Double?,
        current: PlayerLandscapeSide?
    ) -> PlayerLandscapeSide {
        if let gravityX, let gravityY, let gravityZ,
           let side = PlayerLandscapeSide.interfaceSide(gravityX: gravityX, y: gravityY, z: gravityZ) {
            return side
        }
        if let side = PlayerLandscapeSide.interfaceSide(deviceOrientation: deviceOrientation) {
            return side
        }
        return current ?? .right
    }
}

/// Turns a plain iPhone back to portrait before the player cover goes away.
///
/// UIKit holds a rotation requested during a dismissal until the transition has
/// finished, so rotating from `viewWillDisappear` alone shows the navigation UI
/// in landscape for about half a second. `MainTabView` waits for this first.
@MainActor
enum PlayerCoverCloseRotation {
    fileprivate static weak var session: PlayerLandscapeOrientationSession?
    private static let rotationDuration: Duration = .milliseconds(350)

    /// Returns straight away unless the interface really has to turn.
    static func rotateToPortrait() async {
        guard session?.beginClosing() == true else { return }
        try? await Task.sleep(for: rotationDuration)
    }

    /// Playback restarted before the cover left, so it stays up.
    static func cancel() {
        session?.cancelClosing()
    }
}

/// Makes one controller report `.landscape` until released.
///
/// SwiftUI's full-screen cover owns the hosting controller, and UIKit asks
/// that controller — not a child — for `supportedInterfaceOrientations`. The
/// subclass is attached to the live instance so the cover allows both
/// landscape sides and no longer allows portrait, which is what rotates the
/// interface while Portrait Orientation Lock is on.
@MainActor
enum PlayerLandscapeHostLock {
    private static var originals: [ObjectIdentifier: AnyClass] = [:]

    static func engage(_ controller: UIViewController) {
        let id = ObjectIdentifier(controller)
        if originals[id] != nil {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            return
        }
        let original: AnyClass = object_getClass(controller) ?? type(of: controller)
        let subclass = landscapeClass(of: original)
        guard subclass !== original else { return }
        originals[id] = original
        object_setClass(controller, subclass)
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    static func release(_ controller: UIViewController) {
        let id = ObjectIdentifier(controller)
        guard let original = originals.removeValue(forKey: id) else { return }
        object_setClass(controller, original)
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func landscapeClass(of original: AnyClass) -> AnyClass {
        let name = "DuskPlayerLandscapeHost_" + String(cString: class_getName(original))
        if let existing = NSClassFromString(name) {
            return existing
        }
        guard let subclass = objc_allocateClassPair(original, name, 0) else {
            return original
        }
        let selector = #selector(getter: UIViewController.supportedInterfaceOrientations)
        guard
            let method = class_getInstanceMethod(UIViewController.self, selector),
            let encoding = method_getTypeEncoding(method)
        else {
            return original
        }
        let block: @convention(block) (AnyObject) -> UInt = { _ in
            UIInterfaceOrientationMask.landscape.rawValue
        }
        guard class_addMethod(subclass, selector, imp_implementationWithBlock(block), encoding) else {
            return original
        }
        objc_registerClassPair(subclass)
        return subclass
    }
}

/// Sets the iPhone player's orientations while the cover is up: forced
/// landscape with the setting on, free rotation with it off on a plain iPhone.
/// Rotates the interface back as soon as the cover starts leaving.
@MainActor
final class PlayerLandscapeOrientationSession {
    private(set) var isActive = false
    private var host: UIViewController?
    private var scene: UIWindowScene?
    private var savedMask: UIInterfaceOrientationMask?
    private var side: PlayerLandscapeSide?
    private var lastDeviceOrientation: UIDeviceOrientation = .unknown
    private var lastGravity: (x: Double, y: Double, z: Double)?
    private var generation = 0
    private var pendingRestore: (scene: UIWindowScene, mask: UIInterfaceOrientationMask)?
    private var motion: CMMotionManager?
    private var deviceObserver: NSObjectProtocol?
    private var startedDeviceNotifications = false
    private var isClosing = false
    var onCloseCancelled: (() -> Void)?

    func update(forceLandscape: Bool, anchor: UIViewController) {
        guard !isClosing else { return }
        if PlayerLandscapePolicy.shouldForce(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            alwaysPlayInLandscape: forceLandscape
        ) {
            activate(anchor: anchor)
        } else if AppOrientationPolicy.isPlainPhone {
            allowRotation(anchor: anchor)
        } else {
            deactivate()
        }
    }

    /// Releases the player's orientations ahead of the cover's dismissal.
    /// False when nothing needs to rotate.
    func beginClosing() -> Bool {
        guard AppOrientationPolicy.isPlainPhone, scene?.interfaceOrientation.isLandscape == true else {
            return false
        }
        isClosing = true
        deactivate()
        return true
    }

    func cancelClosing() {
        guard isClosing else { return }
        isClosing = false
        onCloseCancelled?()
    }

    func deactivate() {
        guard isActive || host != nil || scene != nil else { return }
        generation += 1
        stopObserving()
        let host = self.host
        let scene = self.scene
        let restored = AppOrientationPolicy.maskAfterPlayer(
            isPlainPhone: AppOrientationPolicy.isPlainPhone,
            previous: self.savedMask
        )
        let generation = self.generation
        self.host = nil
        self.scene = nil
        self.savedMask = nil
        self.side = nil
        self.lastGravity = nil
        self.isActive = false
        self.pendingRestore = nil
        PlayerOrientationApplicationMask.player = nil
        if let host {
            PlayerLandscapeHostLock.release(host)
            host.setNeedsUpdateOfSupportedInterfaceOrientations()
            host.presentingViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene?.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let scene else { return }
        pendingRestore = (scene, restored)
        send(restored, generation: generation, stillActive: false)
    }

    /// Physical orientation from `UIDevice`. Ignored for portrait while a
    /// landscape side is already applied, including when the lock freezes this
    /// value on portrait.
    func note(deviceOrientation: UIDeviceOrientation) {
        lastDeviceOrientation = deviceOrientation
        applyPolicy()
    }

    /// Physical orientation from CoreMotion. This is what flips left/right
    /// while Portrait Orientation Lock is on.
    func note(gravityX: Double, y: Double, z: Double) {
        lastGravity = (gravityX, y, z)
        applyPolicy()
    }

    /// Setting off on a plain iPhone: the player follows the phone, and the
    /// navigation UI underneath stays behind the portrait app mask once the
    /// cover closes.
    private func allowRotation(anchor: UIViewController) {
        guard let scene = anchor.view.window?.windowScene else { return }
        if isActive {
            stopObserving()
            if let host {
                PlayerLandscapeHostLock.release(host)
            }
            host = nil
            side = nil
            lastGravity = nil
            isActive = false
        }
        guard self.scene !== scene || PlayerOrientationApplicationMask.player != .allButUpsideDown else {
            return
        }
        self.scene = scene
        generation += 1
        pendingRestore = nil
        PlayerOrientationApplicationMask.player = .allButUpsideDown
        anchor.setNeedsUpdateOfSupportedInterfaceOrientations()
        presentedHost(for: anchor).setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func activate(anchor: UIViewController) {
        guard let scene = anchor.view.window?.windowScene else { return }
        let host = presentedHost(for: anchor)
        if self.host === host, isActive {
            applyPolicy()
            return
        }
        self.host = host
        self.scene = scene
        self.savedMask = scene.interfaceOrientation.playerLandscapeMask
        self.side = nil
        self.lastDeviceOrientation = UIDevice.current.orientation
        self.lastGravity = nil
        self.isActive = true
        generation += 1
        PlayerOrientationApplicationMask.player = .landscape
        PlayerLandscapeHostLock.engage(host)
        host.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        applyPolicy()
        startObserving()
    }

    private func applyPolicy() {
        guard isActive, scene != nil, host != nil else { return }
        let gravity = lastGravity
        let next = PlayerLandscapePolicy.side(
            deviceOrientation: lastDeviceOrientation,
            gravityX: gravity?.x,
            gravityY: gravity?.y,
            gravityZ: gravity?.z,
            current: side
        )
        guard next != side, let scene, let host else { return }
        side = next
        PlayerLandscapeHostLock.engage(host)
        host.setNeedsUpdateOfSupportedInterfaceOrientations()
        send(next.mask, generation: generation, stillActive: true)
    }

    private func send(
        _ mask: UIInterfaceOrientationMask,
        generation: Int,
        stillActive: Bool
    ) {
        let scene = stillActive ? self.scene : pendingRestore?.scene
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard self.generation == generation else { return }
            if stillActive {
                guard self.isActive, self.side?.mask == mask else { return }
                self.scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            } else if let pending = self.pendingRestore, !self.isActive, pending.mask == mask,
                      PlayerOrientationApplicationMask.player == nil {
                pending.scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }
        }
    }

    private func presentedHost(for anchor: UIViewController) -> UIViewController {
        var current: UIViewController? = anchor
        var presented: UIViewController?
        while let controller = current {
            if controller.presentingViewController != nil {
                presented = controller
            }
            current = controller.parent
        }
        if let presented {
            return presented
        }
        if let presented = anchor.view.window?.rootViewController?.presentedViewController {
            return presented
        }
        return anchor
    }

    private func startObserving() {
        let manager = CMMotionManager()
        // Device motion is the orientation-lock-proof reading. The simulator
        // has none; `UIDevice` covers that path. No motion-usage string: this
        // is gravity, not activity recognition.
        if manager.isDeviceMotionAvailable {
            manager.deviceMotionUpdateInterval = 0.2
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let gravity = motion?.gravity else { return }
                let sample = (gravity.x, gravity.y, gravity.z)
                Task { @MainActor in
                    self?.note(gravityX: sample.0, y: sample.1, z: sample.2)
                }
            }
            motion = manager
        } else if manager.isAccelerometerAvailable {
            manager.accelerometerUpdateInterval = 0.2
            manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let acceleration = data?.acceleration else { return }
                let sample = (acceleration.x, acceleration.y, acceleration.z)
                Task { @MainActor in
                    self?.note(gravityX: sample.0, y: sample.1, z: sample.2)
                }
            }
            motion = manager
        }

        if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            startedDeviceNotifications = true
        }
        deviceObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let orientation = UIDevice.current.orientation
            Task { @MainActor in
                self?.note(deviceOrientation: orientation)
            }
        }
    }

    private func stopObserving() {
        motion?.stopDeviceMotionUpdates()
        motion?.stopAccelerometerUpdates()
        motion = nil
        if let deviceObserver {
            NotificationCenter.default.removeObserver(deviceObserver)
            self.deviceObserver = nil
        }
        if startedDeviceNotifications {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            startedDeviceNotifications = false
        }
    }
}

private extension UIInterfaceOrientation {
    var playerLandscapeMask: UIInterfaceOrientationMask {
        switch self {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
    }
}

/// Clear child of the player cover. UIKit ignores this controller's own
/// orientations; the session retargets the cover's hosting controller.
final class PlayerLandscapeAnchorController: UIViewController {
    private let session = PlayerLandscapeOrientationSession()
    private var forceLandscape = false

    override func viewDidLoad() {
        super.viewDidLoad()
        session.onCloseCancelled = { [weak self] in self?.sync() }
    }

    func setForceLandscape(_ forceLandscape: Bool) {
        self.forceLandscape = forceLandscape
        sync()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PlayerCoverCloseRotation.session = session
        sync()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Alerts and sheets also disappear this view. Restore only when the
        // player cover itself is leaving, then again from `dismantle`.
        guard isPlayerCoverDismissing else { return }
        session.deactivate()
    }

    private func sync() {
        session.update(forceLandscape: forceLandscape, anchor: self)
    }

    private var isPlayerCoverDismissing: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isBeingDismissed { return true }
            current = controller.parent
        }
        return false
    }
}

struct PlayerLandscapeOrientationAnchor: UIViewControllerRepresentable {
    var forceLandscape: Bool

    func makeUIViewController(context: Context) -> PlayerLandscapeAnchorController {
        let controller = PlayerLandscapeAnchorController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: PlayerLandscapeAnchorController, context: Context) {
        controller.setForceLandscape(forceLandscape)
    }

    static func dismantleUIViewController(_ controller: PlayerLandscapeAnchorController, coordinator: ()) {
        controller.setForceLandscape(false)
    }
}

/// Installed on the iPhone player cover only. With the setting off, rotation
/// stays with the system and the orientation lock while the cover is up. On
/// iPad the cover is unchanged.
struct PlayerPhoneLandscapeModifier: ViewModifier {
    @Environment(UserPreferences.self) private var preferences

    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.background {
                PlayerLandscapeOrientationAnchor(forceLandscape: preferences.alwaysPlayInLandscape)
            }
        } else {
            content
        }
    }
}
#endif
