import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension PlexService {
    func imageURL(for path: String?, width: Int? = nil, height: Int? = nil) -> URL? {
        guard let path else { return nil }

        let requestSize = imageRequestSize(width: width, height: height)
        if requestSize.hasDimensions,
           let transcodedURL = transcodedImageURL(for: path, size: requestSize) {
            return transcodedURL
        }

        return directImageURL(for: path)
    }

    func directImageURL(for path: String) -> URL? {
        guard let urlString = imageRequestURLString(for: path, includeToken: false) else {
            return nil
        }
        return URL(string: urlString)
    }

    func transcodedImageURL(for path: String, size: ImageRequestSize) -> URL? {
        guard let baseURL = serverBaseURL,
              let originalURLString = imageRequestURLString(for: path, includeToken: true) else {
            return nil
        }

        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard var components = URLComponents(string: base + "/photo/:/transcode") else {
            return nil
        }

        var items = [
            URLQueryItem(name: "width", value: String(max(size.width ?? 1, 1))),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "0"),
            URLQueryItem(name: "url", value: originalURLString),
        ]

        if let height = size.height {
            items.append(URLQueryItem(name: "height", value: String(height)))
        }

        components.queryItems = items
        return components.url
    }

    func imageData(for url: URL) async throws -> Data {
        if shouldAuthenticateImageRequest(for: url) {
            return try await rawImageServerRequest(url: url)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        return try await executeBinaryRequest(request)
    }

    func shouldAuthenticateImageRequest(for url: URL) -> Bool {
        guard let serverBaseURL else { return false }

        let normalizedURLPort = url.port ?? defaultPort(for: url.scheme)
        let normalizedServerPort = serverBaseURL.port ?? defaultPort(for: serverBaseURL.scheme)

        return url.scheme?.lowercased() == serverBaseURL.scheme?.lowercased()
            && url.host?.lowercased() == serverBaseURL.host?.lowercased()
            && normalizedURLPort == normalizedServerPort
    }

    private func rawImageServerRequest(url: URL) async throws -> Data {
        if preferredServerToken == nil {
            try await recoverServerAuthorizationIfPossible()
        }

        do {
            return try await sendImageServerRequest(url: url)
        } catch let error as PlexServiceError where error == .unauthorized {
            plexAuthLogger.notice("Image request unauthorized for \(url.path, privacy: .public); attempting token refresh")
            try await recoverServerAuthorizationIfPossible()
            do {
                return try await sendImageServerRequest(url: url)
            } catch let retryError as PlexServiceError where retryError == .unauthorized {
                clearServer()
                throw retryError
            }
        }
    }

    private func sendImageServerRequest(url: URL) async throws -> Data {
        guard let serverToken = preferredServerToken else {
            throw isAuthenticationFresh ? PlexServiceError.authenticationPending : PlexServiceError.unauthorized
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        applyHeaders(to: &request, token: serverToken)

        return try await executeRequest(request)
    }

    private func executeBinaryRequest(_ request: URLRequest) async throws -> Data {
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

    func imageRequestURLString(for path: String, includeToken: Bool) -> String? {
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return absoluteURL.absoluteString
        }

        guard let baseURL = serverBaseURL else { return nil }
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard var components = URLComponents(string: base + path) else { return nil }

        if includeToken, let token = preferredServerToken {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
            components.queryItems = items
        }

        return components.url?.absoluteString
    }

    func imageRequestSize(width: Int?, height: Int?) -> ImageRequestSize {
        ImageRequestSize(
            width: scaledImageDimension(width),
            height: scaledImageDimension(height)
        )
    }

    func scaledImageDimension(_ dimension: Int?) -> Int? {
        guard let dimension, dimension > 0 else { return nil }
        return Int(ceil(Double(dimension) * Double(displayScale)))
    }

    var displayScale: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.scale
        #else
        1
        #endif
    }

    private func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

struct ImageRequestSize {
    let width: Int?
    let height: Int?

    var hasDimensions: Bool {
        width != nil || height != nil
    }
}
