import CryptoKit
import Foundation

struct SeerrTrustFailure: Equatable, Sendable {
    var host: String
    var port: Int
    var fingerprint: String
}

/// Redirect and TLS policy for Seerr. Certificate pins are leaf SHA-256
/// values the user accepted for one host and port.
final class SeerrURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: String] = [:]
    private var pendingTrustFailure: SeerrTrustFailure?

    func replacePins(_ pins: [String: String]) {
        lock.lock()
        self.pins = pins
        lock.unlock()
    }

    func allow(key: String, fingerprint: String) {
        lock.lock()
        pins[key] = fingerprint
        lock.unlock()
    }

    func prepareForRequest() {
        lock.lock()
        pendingTrustFailure = nil
        lock.unlock()
    }

    func takeTrustFailure() -> SeerrTrustFailure? {
        lock.lock()
        defer { lock.unlock() }
        let failure = pendingTrustFailure
        pendingTrustFailure = nil
        return failure
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port
        let fingerprint = Self.leafFingerprint(trust)
        let key = SeerrServerURL.trustKey(host: host, port: port)
        lock.lock()
        let pinned = fingerprint.map { pins[key] == $0 } ?? false
        if let fingerprint, !pinned {
            pendingTrustFailure = SeerrTrustFailure(host: host, port: port, fingerprint: fingerprint)
        }
        lock.unlock()

        if pinned {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            // Cancel so the caller can offer to trust this exact certificate.
            // Default handling fails the same way but does not keep the fingerprint.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let current = response.url ?? task.originalRequest?.url
        guard let current, let redirected = request.url else {
            completionHandler(nil)
            return
        }
        switch SeerrServerURL.redirectDecision(from: current, to: redirected) {
        case .follow:
            completionHandler(request)
        case .rejectLogin, .rejectCrossOrigin:
            completionHandler(nil)
        }
    }

    private static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else {
            return nil
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
