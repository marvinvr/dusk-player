import Foundation
import OSLog

extension PlexService {
    /// Resolves the linked account's Plex Home and restores an automatically
    /// signed-in member when possible.
    ///
    /// Existing installations get one compatibility escape hatch: if their
    /// first Home lookup after upgrading fails transiently, a previously
    /// connected legacy session remains usable for that launch. Once a Home
    /// lookup succeeds, known multi-user accounts always fail closed.
    func bootstrapHomeSession() async throws {
        guard let primaryAccountToken else {
            throw PlexServiceError.notAuthenticated
        }

        do {
            async let fetchedUsers = fetchHomeUsers(primaryToken: primaryAccountToken)
            async let fetchedPrimaryUser = fetchPrimaryAccountIdentity(primaryToken: primaryAccountToken)

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
                if try await validateRestoredHomeSession(
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
            clearServer()
            activeAccountToken = primaryAccountToken
            activeHomeUser = nil
            currentUser = nil
            accountSubscriptionActive = nil
            homeSelectionRequested = true
            hasRememberedHomeUserToken = false
            KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
            markHomeBootstrapCompleted()
        } catch {
            let migrationCompleted = UserDefaults.standard.bool(
                forKey: Self.defaultsHomeMigrationCompletedKey
            )
            if !migrationCompleted, connectedServer != nil, serverBaseURL != nil {
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

    /// Switches the active Plex identity. The PIN is sent only in this request
    /// and is never written to Keychain, UserDefaults, logs, or a model.
    func switchHomeUser(
        _ user: PlexHomeUser,
        pin: String?,
        remember: Bool
    ) async throws {
        guard homeUsers.contains(where: { $0.id == user.id }) else {
            throw PlexServiceError.homeUserUnavailable
        }
        guard let primaryAccountToken else {
            throw PlexServiceError.notAuthenticated
        }

        let normalizedPIN = pin?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if user.isProtected, normalizedPIN == nil {
            throw PlexServiceError.homePINRequired
        }

        let responseData: Data
        do {
            responseData = try await rawPlexTVRequest(
                method: "POST",
                path: "/api/home/users/\(user.id)/switch",
                queryItems: normalizedPIN.map { [URLQueryItem(name: "pin", value: $0)] },
                accountToken: primaryAccountToken,
                retriesFreshAuthentication: false
            )
        } catch let error as PlexServiceError {
            if user.isProtected,
               error == .unauthorized || error == .httpError(statusCode: 403) {
                throw PlexServiceError.homePINIncorrect
            }
            throw error
        }

        guard let switchedToken = switchToken(from: responseData) else {
            throw PlexServiceError.decodingError(
                "Plex did not return an account token when switching Home users."
            )
        }

        // Commit only after the switch succeeds, so a wrong PIN leaves the
        // existing playback/session state intact.
        clearServer()
        activeAccountToken = switchedToken
        activeHomeUser = user
        currentUser = nil
        accountSubscriptionActive = nil
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
        guard hasPlexHome else { return }
        homeSelectionRequested = true
    }

    /// Lets a presented picker be dismissed when it was opened from Settings.
    /// Startup selection remains mandatory because it has no active Home user.
    func cancelHomeUserSelection() {
        guard activeHomeUser != nil else { return }
        homeSelectionRequested = false
    }

    func setAutomaticHomeSignIn(_ enabled: Bool) {
        automaticHomeSignIn = enabled
    }

    func automaticHomeSignInDidChange() {
        let enabled = automaticHomeSignIn
        UserDefaults.standard.set(enabled, forKey: Self.defaultsAutomaticHomeSignInKey)

        guard enabled else {
            hasRememberedHomeUserToken = false
            KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
            return
        }

        guard activeHomeUser != nil, let activeAccountToken else { return }
        hasRememberedHomeUserToken = true
        KeychainHelper.save(
            key: Self.keychainActiveHomeTokenKey,
            data: Data(activeAccountToken.utf8)
        )
    }

    private func fetchHomeUsers(primaryToken: String) async throws -> [PlexHomeUser] {
        let data = try await rawPlexTVRequest(
            path: "/api/v2/home/users",
            accountToken: primaryToken
        )
        return try decodeHomeUsers(from: data)
    }

    private func fetchPrimaryAccountIdentity(primaryToken: String) async throws -> PlexUser {
        try await plexTVRequest(
            path: "/api/v2/user",
            accountToken: primaryToken
        )
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
        accountSubscriptionActive = nil
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
        homeBootstrapCompleted = true
        UserDefaults.standard.set(true, forKey: Self.defaultsHomeMigrationCompletedKey)
    }

    private func decodeHomeUsers(from data: Data) throws -> [PlexHomeUser] {
        if let users = try? decoder.decode([PlexHomeUser].self, from: data) {
            return users
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw PlexServiceError.decodingError("Invalid Plex Home users response.")
        }

        let rawUsers: [Any]?
        if let dictionary = object as? [String: Any] {
            rawUsers = Self.userArray(in: dictionary)
        } else {
            rawUsers = nil
        }

        guard let rawUsers else {
            throw PlexServiceError.decodingError(
                "Expected a Plex Home users array or envelope."
            )
        }

        let users = rawUsers.compactMap { rawUser -> PlexHomeUser? in
            guard JSONSerialization.isValidJSONObject(rawUser),
                  let userData = try? JSONSerialization.data(withJSONObject: rawUser) else {
                return nil
            }
            return try? decoder.decode(PlexHomeUser.self, from: userData)
        }

        if users.count != rawUsers.count {
            throw PlexServiceError.decodingError(
                "Plex Home returned users in an unsupported format."
            )
        }
        return users
    }

    private static func userArray(in dictionary: [String: Any]) -> [Any]? {
        for key in ["users", "Users", "User", "Metadata"] {
            if let users = dictionary[key] as? [Any] {
                return users
            }
            if let nested = dictionary[key] as? [String: Any],
               let users = userArray(in: nested) {
                return users
            }
        }

        if let container = dictionary["MediaContainer"] as? [String: Any] {
            return userArray(in: container)
        }
        if let container = dictionary["mediaContainer"] as? [String: Any] {
            return userArray(in: container)
        }
        return nil
    }

    private func switchToken(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let token = Self.switchToken(in: object) {
            return token
        }

        let parserDelegate = PlexHomeSwitchTokenParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        return parser.parse() ? parserDelegate.token : nil
    }

    private static func switchToken(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["authToken", "authenticationToken"] {
                if let token = dictionary[key] as? String,
                   let token = token.nilIfEmpty {
                    return token
                }
            }
            for key in ["user", "User", "account"] {
                if let nested = dictionary[key],
                   let token = switchToken(in: nested) {
                    return token
                }
            }
        }
        return nil
    }

    private func validateRestoredHomeSession(
        user: PlexHomeUser,
        token: String
    ) async throws -> Bool {
        do {
            let account: PlexUser = try await plexTVRequest(
                path: "/api/v2/user",
                accountToken: token,
                retriesFreshAuthentication: false
            )

            if let expectedUUID = user.uuid?.nilIfEmpty,
               let actualUUID = account.uuid?.nilIfEmpty {
                return expectedUUID == actualUUID
            }
            return account.id == user.id
                || (user.username != nil && user.username == account.username)
        } catch let error as PlexServiceError
            where error == .unauthorized || error == .httpError(statusCode: 403) {
            plexAuthLogger.notice(
                "Remembered Plex Home token is no longer valid; requiring user selection"
            )
            return false
        } catch {
            // The primary Home list already confirmed this member still exists.
            // A non-auth validation failure should not discard a remembered
            // offline-capable identity due to a transient Plex response.
            plexAuthLogger.notice(
                "Could not validate remembered Plex Home token: \(error.localizedDescription, privacy: .public)"
            )
            return true
        }
    }
}

private final class PlexHomeSwitchTokenParser: NSObject, XMLParserDelegate {
    private(set) var token: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard token == nil else { return }
        token = attributeDict["authenticationToken"]?.nilIfEmpty
            ?? attributeDict["authToken"]?.nilIfEmpty
    }
}
