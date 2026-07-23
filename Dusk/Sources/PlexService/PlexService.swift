import Foundation
import OSLog

let plexAuthLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexAuth"
)

@MainActor
@Observable
final class PlexService {
    /// Durable credential created by the normal Plex sign-in flow. This token
    /// belongs to the linked full account and is the only credential allowed to
    /// enumerate or switch Plex Home members.
    var primaryAccountToken: String?
    /// Credential used for account-scoped API calls in the current session.
    /// It equals `primaryAccountToken` outside Plex Home and becomes the token
    /// returned by the Home switch endpoint for another member.
    var activeAccountToken: String?
    var authTokenUpdatedAt: Date?
    var currentUser: PlexUser?
    private(set) var connectedServer: PlexServer?
    var serverBaseURL: URL?
    private(set) var serverAuthToken: String?
    /// The connection the current session was established through (set when a
    /// probe wins in `connect`). Used to tell local from remote/relay playback.
    private(set) var activeConnection: PlexConnection?
    /// Cached account entitlement: nil = unknown/not fetched, true/false = known.
    /// Drives the remote-streaming (Plex Pass) restriction check.
    var accountSubscriptionActive: Bool?
    var homeUsers: [PlexHomeUser] = []
    var activeHomeUser: PlexHomeUser?
    var homeBootstrapCompleted = false
    var homeSelectionRequested = false
    var primaryProfileID: String?
    var hasRememberedHomeUserToken = false

    /// Compatibility name for the account token used by existing service code.
    /// New account operations should choose `primaryAccountToken` or
    /// `activeAccountToken` explicitly.
    var authToken: String? { activeAccountToken }

    var isAuthenticated: Bool { primaryAccountToken != nil }
    var isConnected: Bool { serverBaseURL != nil }
    var hasPlexHome: Bool { homeUsers.count > 1 }
    var activeProfileID: String? {
        if needsHomeUserSelection, activeHomeUser == nil {
            return nil
        }
        return activeHomeUser?.stableProfileID
            ?? currentUser?.uuid?.nilIfEmpty
            ?? (activeAccountToken == primaryAccountToken ? primaryProfileID : nil)
    }
    var needsHomeUserSelection: Bool {
        homeBootstrapCompleted && hasPlexHome && homeSelectionRequested
    }
    var isSessionReady: Bool {
        isAuthenticated
            && homeBootstrapCompleted
            && activeProfileID != nil
            && !needsHomeUserSelection
    }
    var shouldAdoptLegacyProfileData: Bool {
        homeBootstrapCompleted
            && primaryProfileID != nil
            && activeAccountToken == primaryAccountToken
            && (activeHomeUser == nil || activeHomeUser?.stableProfileID == primaryProfileID)
    }
    var automaticHomeSignIn = true {
        didSet {
            automaticHomeSignInDidChange()
        }
    }

    let clientIdentifier: String
    let session: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    static let plexTVBase = "https://plex.tv"
    /// Kept at the legacy name so existing users' linked-account credential
    /// migrates without requiring another sign-in.
    static let keychainTokenKey = "PlexAuthToken"
    static let keychainActiveHomeTokenKey = "PlexActiveHomeUserToken"
    static let keychainServerTokenKey = "PlexServerAuthToken"
    static let defaultsClientIDKey = "PlexClientIdentifier"
    static let defaultsServerURLKey = "PlexServerURL"
    static let defaultsServerIDKey = "PlexServerID"
    static let defaultsServerDataKey = "PlexServerData"
    static let defaultsLastGoodConnectionURIKey = "PlexLastGoodConnectionURI"
    static let defaultsActiveHomeUserDataKey = "PlexActiveHomeUserData"
    static let defaultsAutomaticHomeSignInKey = "PlexAutomaticallySignInHomeUser"
    static let defaultsHomeMigrationCompletedKey = "PlexHomeMigrationCompleted"
    static let defaultsPrimaryProfileIDKey = "PlexPrimaryProfileID"
    static let authenticationPropagationRetryWindow: TimeInterval = 20
    static let authenticationPropagationRetryAttempts = 20

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = AppImageCache.shared
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()

        if let stored = UserDefaults.standard.string(forKey: Self.defaultsClientIDKey) {
            clientIdentifier = stored
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: Self.defaultsClientIDKey)
            clientIdentifier = id
        }

        if let data = KeychainHelper.load(key: Self.keychainTokenKey),
           let token = String(data: data, encoding: .utf8) {
            primaryAccountToken = token.nilIfEmpty
        }

        if let profileData = UserDefaults.standard.data(forKey: Self.defaultsActiveHomeUserDataKey),
           let profile = try? decoder.decode(PlexHomeUser.self, from: profileData) {
            activeHomeUser = profile
        }

        let shouldAutomaticallySignIn: Bool
        if UserDefaults.standard.object(forKey: Self.defaultsAutomaticHomeSignInKey) == nil {
            shouldAutomaticallySignIn = true
        } else {
            shouldAutomaticallySignIn = UserDefaults.standard.bool(
                forKey: Self.defaultsAutomaticHomeSignInKey
            )
        }
        automaticHomeSignIn = shouldAutomaticallySignIn

        primaryProfileID = UserDefaults.standard
            .string(forKey: Self.defaultsPrimaryProfileIDKey)?
            .nilIfEmpty

        if shouldAutomaticallySignIn,
           activeHomeUser != nil,
           let data = KeychainHelper.load(key: Self.keychainActiveHomeTokenKey),
           let token = String(data: data, encoding: .utf8)?.nilIfEmpty {
            activeAccountToken = token
            hasRememberedHomeUserToken = true
        } else {
            activeAccountToken = primaryAccountToken
        }

        if let data = KeychainHelper.load(key: Self.keychainServerTokenKey),
           let token = String(data: data, encoding: .utf8) {
            serverAuthToken = token.nilIfEmpty
        }

        if let urlString = UserDefaults.standard.string(forKey: Self.defaultsServerURLKey),
           let url = URL(string: urlString) {
            serverBaseURL = url
        }

        if let serverData = UserDefaults.standard.data(forKey: Self.defaultsServerDataKey),
           let server = try? decoder.decode(PlexServer.self, from: serverData) {
            // Migrate server tokens persisted by older releases into Keychain,
            // then immediately keep only the tokenless snapshot in memory and
            // UserDefaults.
            let persistedServerToken = server.usableAccessToken
            connectedServer = server.withoutAccessToken
            if serverAuthToken == nil, let persistedServerToken {
                serverAuthToken = persistedServerToken
                KeychainHelper.save(
                    key: Self.keychainServerTokenKey,
                    data: Data(persistedServerToken.utf8)
                )
            }
            if let tokenlessData = try? encoder.encode(server.withoutAccessToken) {
                UserDefaults.standard.set(tokenlessData, forKey: Self.defaultsServerDataKey)
            }
        }

        if let serverAuthToken {
            KeychainHelper.save(key: Self.keychainServerTokenKey, data: Data(serverAuthToken.utf8))
        }
    }

    var preferredServerToken: String? {
        serverAuthToken?.nilIfEmpty
    }

    var currentServerIdentifier: String? {
        if let identifier = connectedServer?.clientIdentifier.nilIfEmpty {
            return identifier
        }
        return serverBaseURL?.absoluteString.nilIfEmpty
    }

    /// Last server chosen on this device, retained across Home switches so the
    /// new profile can reconnect to it when that server is still accessible.
    var preferredServerIdentifier: String? {
        connectedServer?.clientIdentifier.nilIfEmpty
            ?? UserDefaults.standard.string(forKey: Self.defaultsServerIDKey)?.nilIfEmpty
    }

    /// The connection the session is running on. Prefers the one recorded when
    /// the probe won; after a cold launch (state restored from disk without a
    /// re-probe) it falls back to matching `serverBaseURL` against the stored
    /// server's connection list by host.
    var resolvedActiveConnection: PlexConnection? {
        if let activeConnection {
            return activeConnection
        }
        guard let serverBaseURL, let connectedServer else { return nil }
        return connectedServer.connections.first { connectionMatches($0, baseURL: serverBaseURL) }
    }

    /// True when the active session runs over the server's local network.
    var isConnectedViaLocalNetwork: Bool {
        resolvedActiveConnection?.local == true
    }

    /// True when the active session runs over a remote or relay connection.
    /// Defaults to false when the connection can't be resolved so callers never
    /// wrongly treat an unknown state as "away from home".
    var isConnectedRemotely: Bool {
        guard let connection = resolvedActiveConnection else { return false }
        return !connection.local
    }

    private func connectionMatches(_ connection: PlexConnection, baseURL: URL) -> Bool {
        guard let host = baseURL.host else { return false }
        for uri in [connection.uri, connection.httpFallbackURI].compactMap({ $0 }) {
            guard let url = URL(string: uri), url.host == host else { continue }
            if let basePort = baseURL.port, let connectionPort = url.port, basePort != connectionPort {
                continue
            }
            return true
        }
        return false
    }

    func setServer(_ server: PlexServer, baseURL: URL, accessToken: String?, connection: PlexConnection? = nil) {
        let tokenlessServer = server.withoutAccessToken
        connectedServer = tokenlessServer
        serverBaseURL = baseURL
        activeConnection = connection
        serverAuthToken = accessToken?.nilIfEmpty ?? server.usableAccessToken
        UserDefaults.standard.set(baseURL.absoluteString, forKey: Self.defaultsServerURLKey)
        UserDefaults.standard.set(server.clientIdentifier, forKey: Self.defaultsServerIDKey)
        if let data = try? encoder.encode(tokenlessServer) {
            UserDefaults.standard.set(data, forKey: Self.defaultsServerDataKey)
        }
        if let serverAuthToken {
            KeychainHelper.save(key: Self.keychainServerTokenKey, data: Data(serverAuthToken.utf8))
        } else {
            KeychainHelper.delete(key: Self.keychainServerTokenKey)
        }
    }

    func clearServer(forgetSelection: Bool = false) {
        connectedServer = nil
        serverBaseURL = nil
        serverAuthToken = nil
        activeConnection = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerURLKey)
        if forgetSelection {
            UserDefaults.standard.removeObject(forKey: Self.defaultsServerIDKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerDataKey)
        KeychainHelper.delete(key: Self.keychainServerTokenKey)
    }
}
