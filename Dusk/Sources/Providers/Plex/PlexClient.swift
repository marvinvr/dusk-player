import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import SystemConfiguration
#endif

/// Plex's request core (docs/jellyfin/04-architecture.md §8): the four
/// `URLSession`s, the `X-Plex-*` headers, sending one request and mapping its
/// status, and the URL and decode helpers. One per `MediaService`, owned by its
/// Plex providers.
///
/// It does not route or heal. Which server a request goes to, the token
/// refresh and re-selecting a failing server's connection stay in
/// `MediaService+Networking`, which calls in here for each attempt.
@MainActor
final class PlexClient {
    let clientIdentifier: String
    let session: URLSession
    /// For the few server reads allowed to outlast `session`'s 30s budget
    /// (`rawServerRequest(timeoutInterval:)` above `requestResourceTimeout`).
    /// Separate so every other call keeps failing fast on a dead endpoint.
    let slowQuerySession: URLSession
    /// Connection selection only: never waits for connectivity, so a dead
    /// candidate fails inside its own timeout instead of hanging the race.
    let probeSession: URLSession
    /// Launch/account discovery must never wait for a route or a long resource timeout.
    let bootstrapSession: URLSession

    /// The shared session's whole-request budget.
    static let bootstrapTimeout: TimeInterval = 3
    static let requestResourceTimeout: TimeInterval = 30

    /// - Parameter urlProtocolClasses: Tests only: serves every session's requests.
    init(clientIdentifier: String, urlProtocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.default
        config.urlCache = AppImageCache.shared
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = Self.requestResourceTimeout
        let slowQueryConfig = URLSessionConfiguration.default
        slowQueryConfig.waitsForConnectivity = true
        slowQueryConfig.timeoutIntervalForResource = 120
        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.waitsForConnectivity = false
        probeConfig.timeoutIntervalForResource = 15
        probeConfig.urlCache = nil
        let bootstrapConfig = URLSessionConfiguration.ephemeral
        bootstrapConfig.waitsForConnectivity = false
        bootstrapConfig.timeoutIntervalForRequest = Self.bootstrapTimeout
        bootstrapConfig.timeoutIntervalForResource = Self.bootstrapTimeout
        bootstrapConfig.urlCache = nil
        if let urlProtocolClasses {
            config.protocolClasses = urlProtocolClasses
            slowQueryConfig.protocolClasses = urlProtocolClasses
            probeConfig.protocolClasses = urlProtocolClasses
            bootstrapConfig.protocolClasses = urlProtocolClasses
        }
        self.session = URLSession(configuration: config, delegate: PlexTransportSessionDelegate(), delegateQueue: nil)
        self.slowQuerySession = URLSession(configuration: slowQueryConfig, delegate: PlexTransportSessionDelegate(), delegateQueue: nil)
        self.probeSession = URLSession(configuration: probeConfig, delegate: PlexTransportSessionDelegate(), delegateQueue: nil)
        self.bootstrapSession = URLSession(configuration: bootstrapConfig, delegate: PlexTransportSessionDelegate(), delegateQueue: nil)
        self.clientIdentifier = clientIdentifier
    }

    // MARK: - Headers

    var basePlexHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": "Dusk",
            "X-Plex-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]
    }

    /// Every Plex header except the token. `ServerPool` is handed this once so a
    /// connection probe is byte-for-byte what a real request would be.
    var plexRequestHeaders: [String: String] {
        var headers = basePlexHeaders

        #if os(tvOS)
        headers["X-Plex-Platform"] = "tvOS"
        headers["X-Plex-Device-Name"] = "Apple TV"
        #elseif os(macOS)
        headers["X-Plex-Platform"] = "macOS"
        headers["X-Plex-Device"] = "Mac"
        headers["X-Plex-Device-Name"] = Self.macDeviceName
        #elseif canImport(UIKit)
        headers["X-Plex-Platform"] = "iOS"
        headers["X-Plex-Device-Name"] = UIDevice.current.name
        #endif

        return headers
    }

    func applyHeaders(to request: inout URLRequest, token: String?) {
        var headers = plexRequestHeaders

        if let token {
            headers["X-Plex-Token"] = token
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    // MARK: - Sending

    /// Refuses a request that would send the token where it must not go.
    func validate(_ request: URLRequest) throws {
        do {
            try PlexTransportSecurity.validate(request)
        } catch {
            throw PlexServiceError.invalidURL
        }
    }

    /// Sends `request` once and maps the outcome onto `PlexServiceError`.
    /// `session` nil means the shared one.
    func send(_ request: URLRequest, using session: URLSession? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await (session ?? self.session).data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw PlexServiceError.requestTimedOut
        } catch {
            throw PlexServiceError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PlexServiceError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw PlexServiceError.unauthorized
        default:
            throw PlexServiceError.httpError(statusCode: http.statusCode)
        }
    }

    // MARK: - Helpers

    /// Decodes a payload with `decoder`, mapping a failure onto `PlexServiceError`.
    func decode<T: Decodable>(_ type: T.Type, from data: Data, using decoder: JSONDecoder) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PlexServiceError.decodingError(String(describing: error))
        }
    }

    func buildURL(base: String, path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        let base = base.hasSuffix("/") ? String(base.dropLast()) : base
        let path = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: base + path) else { return nil }
        if let queryItems, !queryItems.isEmpty {
            let queryNames = Set(queryItems.map(\.name))
            let existingItems = (components.queryItems ?? []).filter { !queryNames.contains($0.name) }
            components.queryItems = existingItems + queryItems
        }
        return PlexTransportSecurity.authenticatedURL(components.url)
    }
}

#if os(macOS)
extension PlexClient {
    /// The Mac's user-facing name (System Settings › General › Sharing), the
    /// counterpart of `UIDevice.current.name`. Read once: the configuration
    /// store is cheap, but the headers are built for every request.
    static let macDeviceName: String = {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return "Mac"
    }()
}
#endif
