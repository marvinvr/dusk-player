import Foundation
import OSLog

/// Sign-in, sign-out and the fresh-sign-in retry. The Plex calls and the
/// account credential are `PlexAccountProvider`'s; this keeps the state
/// transitions (teardown on an account change, the Home reset) in one place.
extension MediaService {
    /// The sign-in host's flows, in registry order. Plex is the only one.
    var signInFlows: [any SignInFlow] { accounts.signInFlows }

    /// The end of every sign-in flow: the account it signed in to and the
    /// credential it obtained.
    func completeSignIn(_ account: StoredAccount, credential: String) {
        switch account.kind {
        case .plex:
            setAuthToken(credential)
        case .jellyfin:
            assertionFailure("No Jellyfin sign-in flow is registered yet")
        }
    }

    func setAuthToken(_ token: String) {
        let normalizedToken = token.nilIfEmpty
        if primaryAccountToken != normalizedToken {
            tearDownServerSessions(forgetServers: true)
            currentUser = nil
            resetHomeSession(clearPreference: true)
        }
        primaryAccountToken = normalizedToken
        activeAccountToken = normalizedToken
        authTokenUpdatedAt = Date()

        plexAuthLogger.notice("Stored new Plex auth token and opened bootstrap retry window")

        plexAccount.saveCredential(primaryAccountToken)
    }

    func clearAuthToken() {
        plexAccount.clearCredential()
        resetHomeSession(clearPreference: true)
        plexAuthLogger.notice("Cleared Plex auth token")
    }

    /// The Plex sign-in flow, for its own screens.
    var plexSignInFlow: PlexSignInFlow { PlexSignInFlow(account: plexAccount) }

    func generatePin(strong: Bool = false) async throws -> PlexPin {
        try await plexSignInFlow.generatePin(strong: strong)
    }

    func checkPin(_ pinId: Int) async throws -> String? {
        try await plexSignInFlow.checkPin(pinId)
    }

    func signOut() {
        tearDownServerSessions(forgetServers: true)
        clearAuthToken()
    }

    func authURL(for pin: PlexPin) -> URL? {
        plexSignInFlow.authURL(for: pin)
    }

    var isAuthenticationFresh: Bool { plexAccount.isAuthenticationFresh }

    func retryAfterFreshAuthentication<T>(
        attempts: Int? = nil,
        delay: Duration = .seconds(1),
        _ operation: () async throws -> T
    ) async throws -> T {
        try await plexAccount.retryAfterFreshAuthentication(attempts: attempts, delay: delay, operation)
    }

    func shouldRetryAfterFreshAuthentication(_ error: Error) -> Bool {
        plexAccount.shouldRetryAfterFreshAuthentication(error)
    }

    private func resetHomeSession(clearPreference: Bool) {
        homeUsers = []
        activeHomeUser = nil
        primaryProfileID = nil
        homeBootstrapCompleted = false
        isUsingOfflineHomeSession = false
        homeSelectionRequested = false
        hasRememberedHomeUserToken = false
        KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsActiveHomeUserDataKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsHomeMigrationCompletedKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsPrimaryProfileIDKey)
        if clearPreference {
            automaticHomeSignIn = true
            UserDefaults.standard.removeObject(forKey: Self.defaultsAutomaticHomeSignInKey)
        }
    }
}
