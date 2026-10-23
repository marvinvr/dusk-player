import Foundation

@MainActor
@Observable
final class SeerrSettingsViewModel {
    var serverURL = ""
    var showsConnectionConfirmation = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var pendingTrust: SeerrTrustFailure?
    private var resolvedServerURL: URL?

    var showsTrustCertificate: Bool {
        pendingTrust?.fingerprint.isEmpty == false
    }

    func load(from service: SeerrService) {
        guard serverURL.isEmpty else { return }
        serverURL = service.configuredBaseURL?.absoluteString ?? ""
    }

    func prepareConnection(using service: SeerrService) async {
        isWorking = true
        errorMessage = nil
        pendingTrust = nil
        resolvedServerURL = nil
        defer { isWorking = false }

        do {
            resolvedServerURL = try await service.resolveServerURL(
                serverURLString: serverURL
            )
            showsConnectionConfirmation = true
        } catch let error as SeerrServiceError {
            note(error)
        } catch {
            note(SeerrServiceError.classifyTransport(error))
        }
    }

    func trustPendingCertificate(using service: SeerrService) async {
        guard let pendingTrust else { return }
        service.trustCertificate(
            host: pendingTrust.host,
            port: pendingTrust.port,
            fingerprint: pendingTrust.fingerprint
        )
        await prepareConnection(using: service)
    }

    func connect(using service: SeerrService) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let destination = resolvedServerURL?.absoluteString ?? serverURL
            try await service.connect(serverURLString: destination)
            serverURL = service.configuredBaseURL?.absoluteString ?? serverURL
            resolvedServerURL = service.configuredBaseURL
        } catch let error as SeerrServiceError {
            note(error)
        } catch {
            note(SeerrServiceError.classifyTransport(error))
        }
    }

    func disconnect(using service: SeerrService) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        await service.disconnect()
        resolvedServerURL = nil
    }

    var confirmationMessage: String {
        let normalized = resolvedServerURL
            ?? (try? SeerrService.normalizedBaseURL(from: serverURL))
        let transportWarning = normalized?.scheme == "http"
            ? " This connection isn’t encrypted."
            : ""
        return "Dusk will try to sign in to Seerr with your current Plex account.\(transportWarning)"
    }

    private func note(_ error: SeerrServiceError) {
        errorMessage = error.localizedDescription
        if case let .tlsUntrusted(host, port, fingerprint) = error, !fingerprint.isEmpty {
            pendingTrust = SeerrTrustFailure(host: host, port: port, fingerprint: fingerprint)
        } else {
            pendingTrust = nil
        }
    }
}
