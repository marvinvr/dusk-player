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

    func scrubPreviewSource(forPartID partID: Int) async -> PlexScrubPreviewSource? {
        guard partID > 0 else { return nil }

        do {
            let data = try await rawScrubPreviewRequest(partID: partID)
            guard !data.isEmpty, data.count <= PlexBIFParser.maxFileSize else { return nil }

            let frames = await Task.detached(priority: .utility) {
                PlexBIFParser.parse(data)
            }.value

            guard !frames.isEmpty else { return nil }
            return PlexScrubPreviewSource(frames: frames)
        } catch {
            return nil
        }
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

    private func rawScrubPreviewRequest(partID: Int) async throws -> Data {
        if preferredServerToken == nil {
            try await recoverServerAuthorizationIfPossible()
        }

        do {
            return try await sendScrubPreviewRequest(partID: partID)
        } catch let error as PlexServiceError where error == .unauthorized {
            try await recoverServerAuthorizationIfPossible()
            return try await sendScrubPreviewRequest(partID: partID)
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

        if let cachedResponse = AppImageCache.cachedResponse(for: request) {
            return cachedResponse.data
        }

        let data = try await executeRequest(request)
        if let cachedResponse = URLCache.shared.cachedResponse(for: request) {
            AppImageCache.storeCachedResponse(cachedResponse, for: request)
        }
        return data
    }

    private func sendScrubPreviewRequest(partID: Int) async throws -> Data {
        guard let baseURL = serverBaseURL else {
            throw PlexServiceError.noServerConnected
        }

        guard let serverToken = preferredServerToken else {
            throw isAuthenticationFresh ? PlexServiceError.authenticationPending : PlexServiceError.unauthorized
        }

        guard let url = buildURL(base: baseURL.absoluteString, path: "/library/parts/\(partID)/indexes/sd") else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        applyHeaders(to: &request, token: serverToken)
        request.setValue("application/octet-stream,image/*,*/*", forHTTPHeaderField: "Accept")

        return try await executeRequest(request)
    }

    private func executeBinaryRequest(_ request: URLRequest) async throws -> Data {
        if let cachedResponse = AppImageCache.cachedResponse(for: request) {
            return cachedResponse.data
        }

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
            if let cachedResponse = URLCache.shared.cachedResponse(for: request) {
                AppImageCache.storeCachedResponse(cachedResponse, for: request)
            }
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

private enum PlexBIFParser {
    static let maxFileSize = 50 * 1024 * 1024

    private static let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

    static func parse(_ data: Data) -> [PlexScrubPreviewFrame] {
        guard data.count >= 72, data.count <= maxFileSize else { return [] }

        let bytes = [UInt8](data)
        guard Array(bytes.prefix(magic.count)) == magic else { return [] }

        let imageCountValue = uint32(at: 12, in: bytes)
        guard imageCountValue > 0 else {
            return []
        }

        let imageCount = Int(imageCountValue)
        let tableEntryCount = imageCount + 1
        guard tableEntryCount > imageCount,
              tableEntryCount <= (bytes.count - 64) / 8 else {
            return []
        }

        let rawMultiplier = uint32(at: 16, in: bytes)
        let timestampMultiplier = Int64(rawMultiplier == 0 ? 1000 : rawMultiplier)

        var frames: [PlexScrubPreviewFrame] = []
        frames.reserveCapacity(imageCount)

        for index in 0..<imageCount {
            let entryOffset = 64 + (index * 8)
            let timestamp = uint32(at: entryOffset, in: bytes)
            let imageOffset = Int(uint32(at: entryOffset + 4, in: bytes))
            let nextImageOffset = Int(uint32(at: entryOffset + 12, in: bytes))

            guard nextImageOffset > imageOffset,
                  nextImageOffset <= data.count else {
                continue
            }

            frames.append(
                PlexScrubPreviewFrame(
                    timestampMs: Int64(timestamp) * timestampMultiplier,
                    imageData: data.subdata(in: imageOffset..<nextImageOffset)
                )
            )
        }

        return frames
    }

    private static func uint32(at offset: Int, in bytes: [UInt8]) -> UInt32 {
        guard offset >= 0, offset + 3 < bytes.count else { return 0 }

        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
