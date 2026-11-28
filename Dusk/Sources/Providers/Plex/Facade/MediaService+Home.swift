import Foundation
import OSLog

/// Profiles: the neutral verbs the profile picker and Settings use, and the
/// Plex Home orchestration behind them. The plex.tv calls are
/// `PlexProfiles`'; the state transitions, teardown and persistence stay here.
extension MediaService {
    /// The primary account's profiles, for the picker.
    var profiles: [Profile] { primaryAccount.profiles.all }

    /// The active profile, when the account has one.
    var activeProfile: Profile? { primaryAccount.profiles.current }

    /// More than one profile to switch between.
    var canSwitchProfiles: Bool { primaryAccount.profiles.canSwitch }

    /// What a protected profile asks for: a Plex Home PIN, or a password.
    var profileSecret: ProfileSecretKind { accountSession?.profileSecret ?? .pin }

    /// The Settings section that lists the profiles.
    var profilesSectionTitle: String { accountSession == nil ? "Plex Home" : "Users" }

    /// Only Plex Home can open on a remembered member or ask at launch;
    /// other accounts always reopen on their last user.
    var offersAutomaticProfileSignIn: Bool { accountSession == nil }

    /// Switches the active profile. `secret` is the Plex Home PIN for a
    /// protected member (a password on accounts with their own session); it
    /// is sent only in the switch request.
    func switchProfile(_ profile: Profile, secret: String?, remember: Bool) async throws {
        if let accountSession {
            let previous = activeProfileID
            try await accountSession.switchProfile(profile, secret: secret)
            if activeProfileID != previous {
                // Server sessions carry the previous user's token.
                tearDownServerSessions()
            }
            return
        }
        guard let user = plexAccount.plexProfiles.homeUser(for: profile) else {
            throw MediaServiceError.homeUserUnavailable
        }
        try await switchHomeUser(user, pin: secret, remember: remember)
    }

    /// Resolves the linked account's Plex Home and restores an automatically
    /// signed-in member when possible.
    ///
    /// Existing installations get one compatibility escape hatch: if their
    /// first Home lookup after upgrading fails transiently, a previously
    /// connected legacy session remains usable for that launch. Once a Home
    /// lookup succeeds, known multi-user accounts require an online selection
    /// or their remembered automatic-sign-in credential. iOS may resume that
    /// cached identity offline, leaving online validation pending.
    func bootstrapHomeSession() async throws {
        // An account with its own session has no Plex Home to resolve.
        if accountSession != nil { return }
        guard let primaryAccountToken else {
            throw MediaServiceError.notAuthenticated
        }

        do {
            let profiles = plexAccount.plexProfiles
            async let fetchedUsers = profiles.fetchHomeUsers(primaryToken: primaryAccountToken)
            async let fetchedPrimaryUser = profiles.fetchPrimaryAccountIdentity(primaryToken: primaryAccountToken)

            let users = try await fetchedUsers
            let primaryUser = try await fetchedPrimaryUser
            updatePrimaryProfileIdentity(from: primaryUser, homeUsers: users)
            homeUsers = users

            if users.count <= 1 {
                activatePrimaryAccount(homeUser: users.first)
                markHomeBootstrapCompleted()
                return
            }

            if automaticHomeSignIn,
               let restoredUser = restoredHomeUser(in: users),
               hasRememberedHomeUserToken,
               let activeAccountToken {
                if try await plexAccount.plexProfiles.validateRestoredHomeSession(
                    user: restoredUser,
                    token: activeAccountToken
                ) {
                    activeHomeUser = restoredUser
                    homeSelectionRequested = false
                    persistActiveHomeUser(restoredUser)
                    markHomeBootstrapCompleted()
                    return
                }
            }

            // An old server token may have owner-level access. Do not let it
            // survive the moment we learn this is a multi-user Home.
            tearDownServerSessions()
            activeAccountToken = primaryAccountToken
            activeHomeUser = nil
            currentUser = nil
            homeSelectionRequested = true
            hasRememberedHomeUserToken = false
            KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
            markHomeBootstrapCompleted()
        } catch {
            guard !Task.isCancelled else { throw error }
            // Connectivity is not an authentication failure. Keep the remembered
            // profile available for its local downloads, without recording an
            // online validation or completing the Home migration.
            if OfflineFallback.permitsCachedSession(after: error),
               restoreOfflineHomeSession() {
                return
            }
            if isUsingOfflineHomeSession {
                isUsingOfflineHomeSession = false
                homeBootstrapCompleted = false
                throw error
            }
            let migrationCompleted = UserDefaults.standard.bool(
                forKey: Self.defaultsHomeMigrationCompletedKey
            )
            if !migrationCompleted, pool.primary != nil {
                // Preserve the pre-Home behavior for one offline/transient
                // upgraded launch. We intentionally do not mark migration as
                // complete, so the next launch checks again.
                activeAccountToken = primaryAccountToken
                homeBootstrapCompleted = true
                homeSelectionRequested = false
                plexAuthLogger.notice(
                    "Plex Home bootstrap unavailable; preserving legacy session until the next launch"
                )
                return
            }
            throw error
        }
    }

    /// Used immediately when NWPathMonitor reports no route, and after a
    /// transport failure during bootstrap. No profile or token is synthesized.
    @discardableResult
    func restoreOfflineHomeSession() -> Bool {
        guard DownloadsFeature.isVisible, isAuthenticated, !homeSelectionRequested,
              OfflineFallback.canRestoreProfile(
                automaticSignIn: automaticHomeSignIn,
                primaryProfileID: primaryProfileID,
                homeProfileID: activeHomeUser?.stableProfileID,
                hasRememberedToken: hasRememberedHomeUserToken && activeAccountToken != nil
              ) else { return false }
        isUsingOfflineHomeSession = true
        homeBootstrapCompleted = true
        homeSelectionRequested = false
        return true
    }

    /// Switches the active Plex identity. The PIN is sent only in this request
    /// and is never written to Keychain, UserDefaults, logs, or a model.
    func switchHomeUser(
        _ user: PlexHomeUser,
        pin: String?,
        remember: Bool
    ) async throws {
        guard homeUsers.contains(where: { $0.id == user.id }) else {
            throw MediaServiceError.homeUserUnavailable
        }
        guard let primaryAccountToken else {
            throw MediaServiceError.notAuthenticated
        }

        let normalizedPIN = pin?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if user.isProtected, normalizedPIN == nil {
            throw MediaServiceError.homePINRequired
        }

        let switchedToken = try await plexAccount.plexProfiles.switchToken(
            for: user,
            pin: normalizedPIN,
            primaryToken: primaryAccountToken
        )

        // Commit only after the switch succeeds, so a wrong PIN leaves the
        // existing playback/session state intact.
        isUsingOfflineHomeSession = false
        tearDownServerSessions()
        activeAccountToken = switchedToken
        activeHomeUser = user
        currentUser = nil
        authTokenUpdatedAt = Date()
        homeSelectionRequested = false
        automaticHomeSignIn = remember
        persistActiveHomeUser(user)

        if remember {
            hasRememberedHomeUserToken = true
            KeychainHelper.save(
                key: Self.keychainActiveHomeTokenKey,
                data: Data(switchedToken.utf8)
            )
        } else {
            hasRememberedHomeUserToken = false
            KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
        }
    }

    /// Makes the shared picker visible without signing out or discarding the
    /// current session. State is cleared only after another user successfully
    /// switches.
    func requestHomeUserSelection() {
        if let accountSession {
            accountSession.requestProfileSelection()
            return
        }
        guard hasPlexHome else { return }
        homeSelectionRequested = true
    }

    /// Lets a presented picker be dismissed when it was opened from Settings.
    /// Startup selection remains mandatory because it has no active Home user.
    func cancelHomeUserSelection() {
        if let accountSession {
            accountSession.cancelProfileSelection()
            return
        }
        guard activeHomeUser != nil else { return }
        homeSelectionRequested = false
    }

    func setAutomaticHomeSignIn(_ enabled: Bool) {
        automaticHomeSignIn = enabled
    }

    func automaticHomeSignInDidChange() {
        plexAccount.persistAutomaticHomeSignIn()
    }

    private func updatePrimaryProfileIdentity(
        from account: PlexUser,
        homeUsers: [PlexHomeUser]
    ) {
        let matchingHomeUser: PlexHomeUser?
        if let uuid = account.uuid?.nilIfEmpty {
            matchingHomeUser = homeUsers.first { $0.uuid == uuid }
        } else {
            matchingHomeUser = homeUsers.first {
                $0.id == account.id
                    || ($0.username != nil && $0.username == account.username)
            }
        }

        let resolvedID = matchingHomeUser?.stableProfileID
            ?? account.uuid?.nilIfEmpty
            ?? "plex-account-\(account.id)"

        primaryProfileID = resolvedID
        UserDefaults.standard.set(resolvedID, forKey: Self.defaultsPrimaryProfileIDKey)
    }

    private func activatePrimaryAccount(homeUser: PlexHomeUser?) {
        activeAccountToken = primaryAccountToken
        activeHomeUser = homeUser
        currentUser = nil
        homeSelectionRequested = false
        KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
        hasRememberedHomeUserToken = false

        if let homeUser {
            persistActiveHomeUser(homeUser)
            if primaryProfileID == nil {
                primaryProfileID = homeUser.stableProfileID
                UserDefaults.standard.set(
                    homeUser.stableProfileID,
                    forKey: Self.defaultsPrimaryProfileIDKey
                )
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsActiveHomeUserDataKey)
        }
    }

    private func restoredHomeUser(in users: [PlexHomeUser]) -> PlexHomeUser? {
        guard let activeHomeUser else { return nil }
        return users.first {
            $0.stableProfileID == activeHomeUser.stableProfileID
                || $0.id == activeHomeUser.id
        }
    }

    private func persistActiveHomeUser(_ user: PlexHomeUser) {
        if let data = try? encoder.encode(user) {
            UserDefaults.standard.set(data, forKey: Self.defaultsActiveHomeUserDataKey)
        }
    }

    private func markHomeBootstrapCompleted() {
        isUsingOfflineHomeSession = false
        homeBootstrapCompleted = true
        UserDefaults.standard.set(true, forKey: Self.defaultsHomeMigrationCompletedKey)
    }
}
