#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Dusk

@Suite("iPhone player landscape", .serialized)
@MainActor
struct PlayerLandscapeOrientationTests {
    @Test func phoneSettingDecidesWhetherToForce() {
        #expect(PlayerLandscapePolicy.shouldForce(isPhone: true, alwaysPlayInLandscape: true))
        #expect(!PlayerLandscapePolicy.shouldForce(isPhone: true, alwaysPlayInLandscape: false))
        #expect(!PlayerLandscapePolicy.shouldForce(isPhone: false, alwaysPlayInLandscape: true))
    }

    @Test func plainPhoneIsPortraitUnlessThePlayerIsUp() {
        #expect(AppOrientationPolicy.mask(isPad: false, isDuo: false, playerMask: nil) == .portrait)
        #expect(AppOrientationPolicy.mask(isPad: false, isDuo: false, playerMask: .landscape) == .landscape)
        #expect(AppOrientationPolicy.mask(isPad: false, isDuo: false, playerMask: .allButUpsideDown) == .allButUpsideDown)
    }

    @Test func iPadAndDuoKeepRotating() {
        #expect(AppOrientationPolicy.mask(isPad: true, isDuo: false, playerMask: nil) == .all)
        #expect(AppOrientationPolicy.mask(isPad: false, isDuo: true, playerMask: nil) == .allButUpsideDown)
        #expect(AppOrientationPolicy.mask(isPad: false, isDuo: true, playerMask: .landscape) == .landscape)
    }

    @Test func leavingThePlayerLandsInPortraitOnlyOnPlainPhones() {
        #expect(AppOrientationPolicy.maskAfterPlayer(isPlainPhone: true, previous: .landscapeLeft) == .portrait)
        #expect(AppOrientationPolicy.maskAfterPlayer(isPlainPhone: false, previous: .landscapeLeft) == .landscapeLeft)
        #expect(AppOrientationPolicy.maskAfterPlayer(isPlainPhone: false, previous: nil) == .portrait)
    }

    @Test func physicalLandscapeMapsToTheOppositeInterfaceSide() {
        #expect(PlayerLandscapeSide.interfaceSide(deviceOrientation: .landscapeLeft) == .right)
        #expect(PlayerLandscapeSide.interfaceSide(deviceOrientation: .landscapeRight) == .left)
        #expect(PlayerLandscapeSide.interfaceSide(deviceOrientation: .portrait) == nil)
        #expect(PlayerLandscapeSide.interfaceSide(deviceOrientation: .faceUp) == nil)

        // Right edge down: device landscapeRight, interface landscapeLeft.
        #expect(PlayerLandscapeSide.interfaceSide(gravityX: 0.92, y: 0.05, z: 0.02) == .left)
        // Left edge down: device landscapeLeft, interface landscapeRight.
        #expect(PlayerLandscapeSide.interfaceSide(gravityX: -0.92, y: 0.04, z: 0.01) == .right)
        #expect(PlayerLandscapeSide.interfaceSide(gravityX: 0.2, y: -0.9, z: 0.05) == nil)
        #expect(PlayerLandscapeSide.interfaceSide(gravityX: 0.1, y: 0.1, z: -0.95) == nil)
    }

    @Test func portraitAndFlatReadingsDoNotLeaveTheCurrentSide() {
        let stayed = PlayerLandscapePolicy.side(
            deviceOrientation: .portrait,
            gravityX: 0.1,
            gravityY: -0.95,
            gravityZ: 0.02,
            current: .left
        )
        #expect(stayed == .left)

        let opened = PlayerLandscapePolicy.side(
            deviceOrientation: .portrait,
            gravityX: nil,
            gravityY: nil,
            gravityZ: nil,
            current: nil
        )
        #expect(opened == .right)

        // CoreMotion wins when the lock has frozen UIDevice on portrait.
        let flipped = PlayerLandscapePolicy.side(
            deviceOrientation: .portrait,
            gravityX: -0.9,
            gravityY: 0.1,
            gravityZ: 0.05,
            current: .right
        )
        #expect(flipped == .right)
        let otherWay = PlayerLandscapePolicy.side(
            deviceOrientation: .portrait,
            gravityX: 0.9,
            gravityY: 0.05,
            gravityZ: 0.02,
            current: .right
        )
        #expect(otherWay == .left)
    }

    @Test func hostingControllerReportsLandscapeOnlyWhileEngaged() {
        let controller = UIViewController()
        let before = orientationMask(of: controller)
        #expect(before.contains(.portrait))
        #expect(before != .landscape)

        PlayerLandscapeHostLock.engage(controller)
        #expect(orientationMask(of: controller) == .landscape)

        let hosting = UIHostingController(rootView: Color.clear)
        PlayerLandscapeHostLock.engage(hosting)
        #expect(orientationMask(of: hosting) == .landscape)
        PlayerLandscapeHostLock.release(hosting)

        PlayerLandscapeHostLock.release(controller)
        #expect(orientationMask(of: controller) == before)
    }

    /// Simulator stand-in for Portrait Orientation Lock: the device orientation
    /// is left where it is (no rotate), and the interface is still asked to go
    /// landscape and to flip. No player and no audio session item.
    @Test func interfaceFollowsLandscapeRequestsWhileDeviceStaysPut() async throws {
        let scene = try #require(await foregroundScene())
        let root = try #require(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        let saved = scene.interfaceOrientation
        let deviceBefore = UIDevice.current.orientation

        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        cover.view.backgroundColor = .black
        let anchor = UIViewController()
        anchor.view.backgroundColor = .clear
        anchor.view.isUserInteractionEnabled = false

        let session = PlayerLandscapeOrientationSession()
        defer {
            session.deactivate()
            PlayerOrientationApplicationMask.player = nil
            if root.presentedViewController != nil {
                root.dismiss(animated: false)
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: saved.playerLandscapeMaskForTest))
        }

        if root.presentedViewController != nil {
            await dismiss(root)
        }
        await present(cover, from: root)
        cover.addChild(anchor)
        anchor.view.frame = cover.view.bounds
        cover.view.addSubview(anchor.view)
        anchor.didMove(toParent: cover)

        session.update(forceLandscape: true, anchor: anchor)
        #expect(session.isActive)
        #expect(orientationMask(of: cover) == .landscape)
        #expect(PlayerOrientationApplicationMask.player == .landscape)

        let becameLandscape = await waitUntil(seconds: 3) {
            scene.interfaceOrientation.isLandscape
        }
        #expect(becameLandscape)
        #expect(UIDevice.current.orientation == deviceBefore)

        let first = scene.interfaceOrientation
        // The other physical side. +x is interface left; -x is interface right.
        let gravityX: Double = first == .landscapeLeft ? -0.92 : 0.92
        session.note(gravityX: gravityX, y: 0.04, z: 0.02)

        let flipped = await waitUntil(seconds: 3) {
            let orientation = scene.interfaceOrientation
            return orientation.isLandscape && orientation != first
        }
        #expect(flipped)
        #expect(UIDevice.current.orientation == deviceBefore)

        session.deactivate()
        #expect(PlayerOrientationApplicationMask.player == nil)
        #expect(orientationMask(of: cover) != .landscape)

        let restored = await waitUntil(seconds: 3) {
            scene.interfaceOrientation == saved
        }
        #expect(restored)
        await dismiss(root)
    }
}

@MainActor
private func orientationMask(of controller: UIViewController) -> UIInterfaceOrientationMask {
    let selector = #selector(getter: UIViewController.supportedInterfaceOrientations)
    let implementation = controller.method(for: selector)
    let function = unsafeBitCast(implementation, to: OrientationMaskIMP.self)
    return UIInterfaceOrientationMask(rawValue: function(controller, selector))
}

private typealias OrientationMaskIMP = @convention(c) (AnyObject, Selector) -> UInt

@MainActor
private func foregroundScene() async -> UIWindowScene? {
    for _ in 0..<50 {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { scene in
            scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        }) {
            return scene
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
}

@MainActor
private func present(_ controller: UIViewController, from root: UIViewController) async {
    await withCheckedContinuation { continuation in
        root.present(controller, animated: false) {
            continuation.resume()
        }
    }
}

@MainActor
private func dismiss(_ root: UIViewController) async {
    await withCheckedContinuation { continuation in
        root.dismiss(animated: false) {
            continuation.resume()
        }
    }
}

@MainActor
private func waitUntil(seconds: Double, _ predicate: () -> Bool) async -> Bool {
    let steps = Int(seconds / 0.05)
    for _ in 0..<steps {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return predicate()
}

private extension UIInterfaceOrientation {
    var playerLandscapeMaskForTest: UIInterfaceOrientationMask {
        switch self {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
    }
}
#endif
