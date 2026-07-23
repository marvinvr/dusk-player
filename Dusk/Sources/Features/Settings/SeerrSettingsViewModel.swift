import Foundation

@MainActor
@Observable
final class SeerrSettingsViewModel {
    var serverURL = ""
    var showsConnectionConfirmation = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private var resolvedServerURL: URL?

    func load(from service: SeerrService) {
        guard serverURL.isEmpty else { return }
        serverURL = service.configuredBaseURL?.absoluteString ?? ""
    }

    func prepareConnection(using service: SeerrService) async {
        isWorking = true
        errorMessage = nil
        resolvedServerURL = nil
        defer { isWorking = false }

        do {
            resolvedServerURL = try await service.resolveServerURL(
                serverURLString: serverURL
            )
            showsConnectionConfirmation = true
        } catch {
            errorMessage = error.localizedDescription
        }
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
        } catch {
            errorMessage = error.localizedDescription
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
}
