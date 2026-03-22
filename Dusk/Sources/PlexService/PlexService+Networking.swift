import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension PlexService {
    var basePlexHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": "Dusk",
            "X-Plex-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]
    }

    func plexTVRequest<T: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        formBody: [String: String]? = nil
    ) async throws -> T {
        guard let url = buildURL(base: Self.plexTVBase, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(to: &request, token: authToken)

        if let formBody {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = formBody.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.query?.data(using: .utf8)
        }

        let data = try await executeRequest(request)
        return try decodeJSON(T.self, from: data)
    }

    func rawServerRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        guard let baseURL = serverBaseURL else {
            throw PlexServiceError.noServerConnected
        }

        guard let url = buildURL(base: baseURL.absoluteString, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }

        if preferredServerToken == nil {
            try await recoverServerAuthorizationIfPossible()
        }

        do {
            return try await sendRawServerRequest(method: method, url: url)
        } catch let error as PlexServiceError where error == .unauthorized {
            plexAuthLogger.notice("Server request unauthorized for \(url.path, privacy: .public); attempting token refresh")
            try await recoverServerAuthorizationIfPossible()
            do {
                return try await sendRawServerRequest(method: method, url: url)
            } catch let retryError as PlexServiceError where retryError == .unauthorized {
                clearServer()
                throw retryError
            }
        }
    }

    private func sendRawServerRequest(method: String, url: URL) async throws -> Data {
        guard let serverToken = preferredServerToken else {
            throw isAuthenticationFresh ? PlexServiceError.authenticationPending : PlexServiceError.unauthorized
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(to: &request, token: serverToken)

        return try await executeRequest(request)
    }

    func recoverServerAuthorizationIfPossible() async throws {
        guard authToken != nil else {
            throw PlexServiceError.unauthorized
        }

        try await retryAfterFreshAuthentication {
            try await refreshConnectedServerAuthorization()
        }
    }

    func fetchMetadata<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> [T] {
        let data = try await rawServerRequest(path: path, queryItems: queryItems)
        let response = try decodeJSON(MetadataResponse<T>.self, from: data)
        return response.MediaContainer.Metadata ?? []
    }

    func fetchDirectories<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> [T] {
        let data = try await rawServerRequest(path: path, queryItems: queryItems)
        let response = try decodeJSON(DirectoryResponse<T>.self, from: data)
        return response.MediaContainer.Directory ?? []
    }

    func fetchHubs(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> [PlexHub] {
        let data = try await rawServerRequest(path: path, queryItems: queryItems)
        let response = try decodeJSON(HubResponse.self, from: data)
        return response.MediaContainer.Hub ?? []
    }

    func applyHeaders(to request: inout URLRequest, token: String?) {
        var headers = basePlexHeaders

        #if os(tvOS)
        headers["X-Plex-Platform"] = "tvOS"
        headers["X-Plex-Device-Name"] = "Apple TV"
        #elseif canImport(UIKit)
        headers["X-Plex-Platform"] = "iOS"
        headers["X-Plex-Device-Name"] = UIDevice.current.name
        #endif

        if let token {
            headers["X-Plex-Token"] = token
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    func executeRequest(_ request: URLRequest) async throws -> Data {
        try await retryAfterFreshAuthentication {
            let data: Data
            let response: URLResponse

            do {
                (data, response) = try await session.data(for: request)
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
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
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
        return components.url
    }
}

struct MetadataResponse<T: Decodable>: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Metadata: [T]?
    }
}

struct DirectoryResponse<T: Decodable>: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Directory: [T]?
    }
}

struct HubResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Hub: [PlexHub]?
    }
}

struct HubItemsResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Metadata: [PlexItem]?
        let Directory: [PlexItem]?
    }
}
