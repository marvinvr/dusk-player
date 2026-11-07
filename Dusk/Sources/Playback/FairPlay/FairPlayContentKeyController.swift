import AVFoundation
import Foundation
import OSLog

private let fairPlayLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "FairPlay"
)

/// What `FairPlayKeyExchange` needs from a key request. `AVContentKeyRequest`
/// conforms; tests use a fake, since AVFoundation cannot build a real one
/// (and simulators cannot produce an SPC at all).
protocol FairPlayKeyRequest: AnyObject {
    /// The `skd://…` URI from the playlist's `EXT-X-KEY`.
    var keyIdentifier: String? { get }
    func makeServerPlaybackContext(certificate: Data, contentIdentifier: Data) async throws -> Data
    func finish(contentKeyContext: Data)
    func fail(_ error: Error)
}

/// One key request through Apple's standard flow: certificate → SPC (bound
/// to the content id from the `skd://` URI) → license server → CKC back into
/// AVFoundation. Any failure is handed to the request, which fails the
/// player item; `onError` gets the readable reason for the player error UI.
struct FairPlayKeyExchange: Sendable {
    let client: FairPlayLicenseClient

    /// `skd://abc` → `abc`, as Apple's sample code and most license servers
    /// expect. Anything without the scheme is used whole.
    static func contentIdentifier(fromKeyIdentifier identifier: String?) -> Data? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
        let id: String
        if identifier.lowercased().hasPrefix("skd://") {
            id = String(identifier.dropFirst("skd://".count))
        } else {
            id = identifier
        }
        guard !id.isEmpty else { return nil }
        return Data(id.utf8)
    }

    func handle(_ request: some FairPlayKeyRequest) async throws {
        do {
            guard let contentIdentifier = Self.contentIdentifier(fromKeyIdentifier: request.keyIdentifier) else {
                throw FairPlayError.missingContentIdentifier
            }
            // Fail before asking for an SPC: without a license server it
            // could never be used.
            guard client.licenseURL != nil else { throw FairPlayError.missingLicenseURL }
            let certificate = try await client.applicationCertificate()
            let spc: Data
            do {
                spc = try await request.makeServerPlaybackContext(
                    certificate: certificate,
                    contentIdentifier: contentIdentifier
                )
            } catch {
                // A rejected certificate stays rejected; fetch it fresh next time.
                if let url = client.certificateURL {
                    await client.certificateCache.remove(for: url)
                }
                throw error
            }
            let ckc = try await client.contentKeyContext(forSPC: spc)
            request.finish(contentKeyContext: ckc)
        } catch {
            request.fail(error)
            throw error
        }
    }
}

/// Owns the `AVContentKeySession` of one IPTV player item. Attached to every
/// IPTV asset — not only the ones whose M3U says FairPlay — so a playlist that
/// signals FairPlay only through `EXT-X-KEY KEYFORMAT="com.apple.streamingkeydelivery"`
/// still reaches the license flow. Unencrypted streams never trigger it.
final class FairPlayContentKeyController: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    private let session: AVContentKeySession
    private let exchange: FairPlayKeyExchange
    private let queue = DispatchQueue(label: "Dusk.FairPlayContentKeyController")
    private let errorLock = NSLock()
    private var _lastError: Error?
    /// Main-actor hook for the engine; called with the reason a key request
    /// failed.
    var onError: (@MainActor @Sendable (Error) -> Void)?

    /// The simulator has no FairPlay: creating a FairPlay key session there
    /// raises an Objective-C exception and takes the app down. Every Apple
    /// device that runs Dusk supports it.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    init(client: FairPlayLicenseClient) {
        session = AVContentKeySession(keySystem: .fairPlayStreaming)
        exchange = FairPlayKeyExchange(client: client)
        super.init()
        session.setDelegate(self, queue: queue)
    }

    /// The most recent failure, which is a far better message than the
    /// generic AVFoundation error the item fails with.
    var lastError: Error? {
        errorLock.withLock { _lastError }
    }

    func attach(to asset: AVURLAsset) {
        session.addContentKeyRecipient(asset)
    }

    func invalidate() {
        session.setDelegate(nil, queue: nil)
        session.expire()
    }

    // MARK: AVContentKeySessionDelegate

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest
    ) {
        handle(keyRequest)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError err: Error
    ) {
        record(err)
    }

    private func handle(_ keyRequest: AVContentKeyRequest) {
        let request = UncheckedKeyRequest(request: keyRequest)
        let exchange = exchange
        Task { [weak self] in
            do {
                try await exchange.handle(request.request)
            } catch {
                fairPlayLogger.error("FairPlay key request failed: \(error.localizedDescription, privacy: .public)")
                self?.record(error)
            }
        }
    }

    private func record(_ error: Error) {
        // Keep the first readable reason: AVFoundation follows ours with its
        // own generic one.
        let shouldReport: Bool = errorLock.withLock {
            if _lastError == nil || !(_lastError is FairPlayError) {
                _lastError = error
                return true
            }
            return false
        }
        guard shouldReport, let onError else { return }
        Task { @MainActor in onError(error) }
    }
}

/// `AVContentKeyRequest` is thread-safe in practice but not `Sendable`.
private struct UncheckedKeyRequest: @unchecked Sendable {
    let request: AVContentKeyRequest
}

extension AVContentKeyRequest: FairPlayKeyRequest {
    var keyIdentifier: String? {
        if let string = identifier as? String { return string }
        if let url = identifier as? URL { return url.absoluteString }
        return nil
    }

    func makeServerPlaybackContext(certificate: Data, contentIdentifier: Data) async throws -> Data {
        try await makeStreamingContentKeyRequestData(
            forApp: certificate,
            contentIdentifier: contentIdentifier,
            options: [AVContentKeyRequestProtocolVersionsKey: [1]]
        )
    }

    func finish(contentKeyContext: Data) {
        processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: contentKeyContext))
    }

    func fail(_ error: Error) {
        processContentKeyResponseError(error)
    }
}
