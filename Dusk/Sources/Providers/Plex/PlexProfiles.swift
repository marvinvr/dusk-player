import Foundation
import OSLog

/// Plex's `ProfileProviding`: the account's Plex Home members as `Profile`s,
/// and the plex.tv calls behind the Home bootstrap and switch, which the
/// facade (`MediaService+Home`) orchestrates.
struct PlexProfiles: ProfileProviding {
    let account: PlexAccountProvider

    var client: PlexClient { account.client }

    @MainActor var canSwitch: Bool { account.state.hasPlexHome }

    @MainActor var all: [Profile] { account.state.homeUsers.map(\.profile) }

    @MainActor var current: Profile? { account.state.activeHomeUser?.profile }

    /// The Home member a `Profile` stands for.
    @MainActor
    func homeUser(for profile: Profile) -> PlexHomeUser? {
        account.state.homeUsers.first { $0.stableProfileID == profile.id }
    }

    // MARK: - plex.tv

    @MainActor
    func fetchHomeUsers(primaryToken: String) async throws -> [PlexHomeUser] {
        let data = try await account.plexTVData(
            path: "/api/v2/home/users",
            accountToken: primaryToken,
            bootstrap: true
        )
        return try Self.decodeHomeUsers(from: data)
    }

    @MainActor
    func fetchPrimaryAccountIdentity(primaryToken: String) async throws -> PlexUser {
        try await account.plexTVRequest(
            path: "/api/v2/user",
            accountToken: primaryToken,
            bootstrap: true
        )
    }

    /// Asks plex.tv for `user`'s token. The PIN is sent only in this request
    /// and is never written anywhere. Throws `homePINIncorrect` for a rejected
    /// PIN on a protected member.
    @MainActor
    func switchToken(
        for user: PlexHomeUser,
        pin: String?,
        primaryToken: String
    ) async throws -> String {
        let responseData: Data
        do {
            responseData = try await account.plexTVData(
                method: "POST",
                path: "/api/home/users/\(user.id)/switch",
                queryItems: pin.map { [URLQueryItem(name: "pin", value: $0)] },
                accountToken: primaryToken,
                retriesFreshAuthentication: false
            )
        } catch let error as PlexServiceError {
            if user.isProtected,
               error == .unauthorized || error == .httpError(statusCode: 403) {
                throw PlexServiceError.homePINIncorrect
            }
            throw error
        }

        guard let switchedToken = Self.switchToken(from: responseData) else {
            throw PlexServiceError.decodingError(
                "Plex did not return an account token when switching Home users."
            )
        }
        return switchedToken
    }

    /// Whether a remembered member token still belongs to `user`.
    @MainActor
    func validateRestoredHomeSession(
        user: PlexHomeUser,
        token: String
    ) async throws -> Bool {
        do {
            let identity: PlexUser = try await account.plexTVRequest(
                path: "/api/v2/user",
                accountToken: token,
                retriesFreshAuthentication: false,
                bootstrap: true
            )

            if let expectedUUID = user.uuid?.nilIfEmpty,
               let actualUUID = identity.uuid?.nilIfEmpty {
                return expectedUUID == actualUUID
            }
            return identity.id == user.id
                || (user.username != nil && user.username == identity.username)
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

    // MARK: - Decoding

    static func decodeHomeUsers(from data: Data) throws -> [PlexHomeUser] {
        let decoder = JSONDecoder()
        if let users = try? decoder.decode([PlexHomeUser].self, from: data) {
            return users
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw PlexServiceError.decodingError("Invalid Plex Home users response.")
        }

        let rawUsers: [Any]?
        if let dictionary = object as? [String: Any] {
            rawUsers = userArray(in: dictionary)
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

    static func switchToken(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let token = switchToken(in: object) {
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
}

extension PlexAccountProvider {
    var profiles: any ProfileProviding { plexProfiles }

    /// The concrete value, for the facade's Plex Home orchestration.
    var plexProfiles: PlexProfiles { PlexProfiles(account: self) }
}

extension PlexHomeUser {
    /// The neutral form the profile picker and Settings show.
    var profile: Profile {
        Profile(
            id: stableProfileID,
            nativeID: String(id),
            displayName: displayName,
            avatarURL: avatarURL,
            isProtected: isProtected,
            isAdmin: isAdmin,
            isRestricted: isRestricted
        )
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
