import Foundation
import OSLog

enum AuthenticationBootstrapError: Error {
    case waitingForPropagation
}

extension PlexService {
    func setAuthToken(_ token: String) {
        if authToken != token {
            clearServer()
            currentUser = nil
        }
        authToken = token.nilIfEmpty
        authTokenUpdatedAt = Date()

        plexAuthLogger.notice("Stored new Plex auth token and opened bootstrap retry window")

        if let authToken {
            KeychainHelper.save(key: Self.keychainTokenKey, data: Data(authToken.utf8))
        } else {
            KeychainHelper.delete(key: Self.keychainTokenKey)
        }
    }

    func clearAuthToken() {
        authToken = nil
        authTokenUpdatedAt = nil
        currentUser = nil
        KeychainHelper.delete(key: Self.keychainTokenKey)
        plexAuthLogger.notice("Cleared Plex auth token")
    }

    func generatePin(strong: Bool = false) async throws -> PlexPin {
        try await plexTVRequest(
            method: "POST",
            path: "/api/v2/pins",
            formBody: strong ? ["strong": "true"] : nil
        )
    }

    func checkPin(_ pinId: Int) async throws -> String? {
        let pin: PlexPin = try await plexTVRequest(path: "/api/v2/pins/\(pinId)")
        return pin.authToken
    }

    func signOut() {
        clearAuthToken()
        clearServer()
    }

    func authURL(for pin: PlexPin) -> URL? {
        URL(string: "https://app.plex.tv/auth#?clientID=\(clientIdentifier)&code=\(pin.code)&context%5Bdevice%5D%5Bproduct%5D=Dusk")
    }

    var isAuthenticationFresh: Bool {
        guard let authTokenUpdatedAt else { return false }
        return Date().timeIntervalSince(authTokenUpdatedAt) < Self.authenticationPropagationRetryWindow
    }

    func retryAfterFreshAuthentication<T>(
        attempts: Int? = nil,
        delay: Duration = .seconds(1),
        _ operation: () async throws -> T
    ) async throws -> T {
        let requestedAttempts = attempts ?? Self.authenticationPropagationRetryAttempts
        let maxAttempts = isAuthenticationFresh ? max(requestedAttempts, 1) : 1
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                let shouldRetry = attempt < maxAttempts && shouldRetryAfterFreshAuthentication(error)

                if shouldRetry {
                    try? await Task.sleep(for: delay)
                    continue
                }

                if isAuthenticationFresh, shouldRetryAfterFreshAuthentication(error) {
                    plexAuthLogger.notice("Authentication bootstrap still pending after retries: \(error.localizedDescription, privacy: .public)")
                    throw PlexServiceError.authenticationPending
                }

                throw error
            }
        }

        throw lastError ?? PlexServiceError.authenticationPending
    }

    func shouldRetryAfterFreshAuthentication(_ error: Error) -> Bool {
        guard isAuthenticationFresh else { return false }

        if error is AuthenticationBootstrapError {
            return true
        }

        guard let plexError = error as? PlexServiceError else {
            return false
        }

        switch plexError {
        case .unauthorized:
            return true
        default:
            return false
        }
    }
}
