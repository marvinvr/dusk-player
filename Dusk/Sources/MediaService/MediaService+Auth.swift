import Foundation
import OSLog

/// Sign-in, sign-out and the fresh-sign-in retry. The Plex calls and the
/// account credential are `PlexAccountProvider`'s; this keeps the state
/// transitions (teardown on an account change, the Home reset) in one place.
extension MediaService {
    /// The sign-in host's flows, in registry order.
    var signInFlows: [any SignInFlow] { accounts.signInFlows }

    /// The primary account's own session when that account runs one: every
    /// provider but Plex, whose Plex Home state the facade runs (`+Home`).
    /// nil while Plex is signed in, and while nobody is.
    var accountSession: (any AccountSession)? {
        guard primaryAccountToken == nil else { return nil }
        return accounts.primaryProvider?.session
    }

    /// The primary account: the one with its own session, else Plex's.
    var primaryAccount: any MediaAccountProvider {
        if accountSession != nil, let provider = accounts.primaryProvider { return provider }
        return accountProvider
    }

    /// The signed-in account's product name ("Plex", "Jellyfin"), for the
    /// account rows and the sign-out prompt.
    var accountProductName: String { primaryAccount.account.displayName }

    /// The account lives on a website Dusk can link to (plex.tv). A Jellyfin
    /// user exists only on its server.
    var hasOnlineAccount: Bool { accountSession == nil }

    /// The end of the Plex sign-in flow: the account it signed in to and the
    /// credential it obtained. Jellyfin's flow ends in
    /// `completeJellyfinSignIn`, because its account is more than a token.
    func completeSignIn(_ account: StoredAccount, credential: String) {
        switch account.kind {
        case .plex:
            setAuthToken(credential)
        case .jellyfin:
            assertionFailure("Jellyfin sign-in completes through completeJellyfinSignIn")
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

    func signOut() {
        tearDownServerSessions(forgetServers: true)
        if let accountSession {
            Task { await accountSession.signOutAll() }
            return
        }
        clearAuthToken()
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
