import Foundation
import OSLog

let plexAuthLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexAuth"
)

@MainActor
@Observable
final class PlexService {
    var authToken: String?
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

    var isAuthenticated: Bool { authToken != nil }
    var isConnected: Bool { serverBaseURL != nil }

    let clientIdentifier: String
    let session: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    static let plexTVBase = "https://plex.tv"
    static let keychainTokenKey = "PlexAuthToken"
    static let keychainServerTokenKey = "PlexServerAuthToken"
    static let defaultsClientIDKey = "PlexClientIdentifier"
    static let defaultsServerURLKey = "PlexServerURL"
    static let defaultsServerIDKey = "PlexServerID"
    static let defaultsServerDataKey = "PlexServerData"
    static let defaultsLastGoodConnectionURIKey = "PlexLastGoodConnectionURI"
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
            authToken = token.nilIfEmpty
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
            connectedServer = server
        }

        if let persistedServerToken = connectedServer?.usableAccessToken {
            if serverAuthToken != persistedServerToken {
                serverAuthToken = persistedServerToken
                KeychainHelper.save(key: Self.keychainServerTokenKey, data: Data(persistedServerToken.utf8))
            }
        } else if let serverAuthToken {
            KeychainHelper.save(key: Self.keychainServerTokenKey, data: Data(serverAuthToken.utf8))
        }
    }

    var preferredServerToken: String? {
        connectedServer?.usableAccessToken ?? serverAuthToken?.nilIfEmpty
    }

    var currentServerIdentifier: String? {
        if let identifier = connectedServer?.clientIdentifier.nilIfEmpty {
            return identifier
        }
        return serverBaseURL?.absoluteString.nilIfEmpty
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
        connectedServer = server
        serverBaseURL = baseURL
        activeConnection = connection
        serverAuthToken = accessToken?.nilIfEmpty ?? server.usableAccessToken
        UserDefaults.standard.set(baseURL.absoluteString, forKey: Self.defaultsServerURLKey)
        UserDefaults.standard.set(server.clientIdentifier, forKey: Self.defaultsServerIDKey)
        if let data = try? encoder.encode(server) {
            UserDefaults.standard.set(data, forKey: Self.defaultsServerDataKey)
        }
        if let serverAuthToken {
            KeychainHelper.save(key: Self.keychainServerTokenKey, data: Data(serverAuthToken.utf8))
        } else {
            KeychainHelper.delete(key: Self.keychainServerTokenKey)
        }
    }

    func clearServer() {
        connectedServer = nil
        serverBaseURL = nil
        serverAuthToken = nil
        activeConnection = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerURLKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerIDKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerDataKey)
        KeychainHelper.delete(key: Self.keychainServerTokenKey)
    }
}
