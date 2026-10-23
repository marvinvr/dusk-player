import Foundation
import Network
import UIKit

/// Triggers the iOS/tvOS Local Network prompt before a LAN Seerr connection.
///
/// A Bonjour browse of the Plex service already declared in the app's
/// Info.plist is what makes the system show the prompt. `kDNSServiceErr_PolicyDenied`
/// (-65570) means the prompt is up or the user has already denied it. A working
/// HTTP connection still wins: the simulator sometimes reports the DNS error
/// even though the request is allowed.
enum SeerrLocalNetworkGate {
    enum Status: Equatable, Sendable {
        case notRequired
        case allowed
        case denied
    }

    static func status(for host: String) async -> Status {
        guard SeerrServerURL.requiresLocalNetworkPermission(host: host) else {
            return .notRequired
        }
        return await Waiter().run()
    }
}

private final class SeerrLocalNetworkWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var continuation: CheckedContinuation<SeerrLocalNetworkGate.Status, Never>?
    private var resumed = false
    private var sawDenial = false
    private var promptVisible = false
    private let queue = DispatchQueue(label: "seerr.local-network")
    private var denyWork: DispatchWorkItem?
    private var capWork: DispatchWorkItem?

    func run() async -> SeerrLocalNetworkGate.Status {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let browser = NWBrowser(
                for: .bonjour(type: "_plexmediasvr._tcp", domain: "local."),
                using: .tcp
            )
            self.browser = browser
            browser.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            browser.start(queue: queue)
            armDenyCheck(after: 5)
            armCap(after: 45)
        }
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            finish(.allowed)
        case .waiting(let error), .failed(let error):
            if isPolicyDenied(error) {
                noteDenial()
            } else {
                finish(.allowed)
            }
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private func noteDenial() {
        lock.lock()
        sawDenial = true
        lock.unlock()
        Task { @MainActor in
            let inactive = UIApplication.shared.applicationState != .active
            self.queue.async {
                self.lock.lock()
                if inactive { self.promptVisible = true }
                self.lock.unlock()
            }
        }
    }

    private func armDenyCheck(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.denyIfStillBlocked()
        }
        denyWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func armCap(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let denied = self.sawDenial
            let waitingOnPrompt = self.promptVisible && denied
            self.lock.unlock()
            if waitingOnPrompt {
                self.queue.asyncAfter(deadline: .now() + 20) {
                    self.finish(.denied)
                }
            } else if denied {
                self.finish(.denied)
            } else {
                // Bonjour never answered. Don't hold the Seerr request for it.
                self.finish(.allowed)
            }
        }
        capWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func denyIfStillBlocked() {
        lock.lock()
        let blocked = sawDenial && !promptVisible
        lock.unlock()
        guard blocked else { return }
        Task { @MainActor in
            let inactive = UIApplication.shared.applicationState != .active
            self.queue.async {
                if inactive {
                    self.lock.lock()
                    self.promptVisible = true
                    self.lock.unlock()
                    return
                }
                self.finish(.denied)
            }
        }
    }

    private func finish(_ status: SeerrLocalNetworkGate.Status) {
        lock.lock()
        guard !resumed, let continuation else {
            lock.unlock()
            return
        }
        resumed = true
        denyWork?.cancel()
        capWork?.cancel()
        let browser = self.browser
        self.browser = nil
        lock.unlock()
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        continuation.resume(returning: status)
    }

    /// DNSServiceErrorType `kDNSServiceErr_PolicyDenied`.
    private func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 {
            return true
        }
        return false
    }
}

private typealias Waiter = SeerrLocalNetworkWaiter
