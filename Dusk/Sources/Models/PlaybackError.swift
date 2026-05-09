import Foundation

/// Errors that can occur during playback.
enum PlaybackError: Error, Sendable, Equatable {
    /// The file format cannot be played directly.
    case unsupportedFormat(container: String?, videoCodec: String?, audioCodec: String?)

    /// Plex could not access the source file for direct play.
    case sourceUnavailable

    /// A network error occurred during playback.
    case networkError(String)

    /// The Plex server is unreachable.
    case serverUnreachable

    /// The auth token is invalid or expired.
    case unauthorized

    /// An unknown error occurred.
    case unknown(String)
}

extension PlaybackError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(container, videoCodec, audioCodec):
            let parts = [container, videoCodec, audioCodec].compactMap { $0 }
            let info = parts.isEmpty ? "" : " [\(parts.joined(separator: " / "))]"
            return "This file couldn't be played directly.\(info)"
        case .sourceUnavailable:
            return "Plex couldn't access or find this file on the server. Check that the file exists and the drive is mounted."
        case let .networkError(message):
            return "Network error: \(message)"
        case .serverUnreachable:
            return "The Plex server is unreachable."
        case .unauthorized:
            return "Authentication expired. Please sign in again."
        case let .unknown(message):
            return message
        }
    }
}

extension PlaybackError {
    private static let directPlayFallbackMessage = "Playback failed while opening the direct-play stream."

    private static let sourceUnavailableMarkers = [
        "failed to open direct stream",
        "direct stream file",
        "couldn't access or find",
        "could not access or find",
        "couldn't access",
        "could not access",
        "cannot access",
        "couldn't find",
        "could not find",
        "cannot find",
        "file not found",
        "no such file",
        "the file exists",
        "drive is mounted",
    ]

    private static let serverUnreachableCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .timedOut,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
    ]

    static func validateDirectPlayURL(_ url: URL) async -> PlaybackError? {
        if url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path) ? nil : .sourceUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                return .networkError("Invalid response")
            }

            guard (200...299).contains(http.statusCode) else {
                let responseText = try await readPrefix(from: bytes, limit: 4096)
                return mapDirectPlayFailure(
                    statusCode: http.statusCode,
                    responseText: responseText,
                    fallback: directPlayFallbackMessage
                )
            }

            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return fromPlaybackFailure(error: error, fallback: directPlayFallbackMessage)
        }
    }

    static func fromPlaybackFailure(
        error: Error?,
        fallback: String = directPlayFallbackMessage
    ) -> PlaybackError {
        guard let error else {
            return .unknown(fallback)
        }

        if let playbackError = error as? PlaybackError {
            return playbackError
        }

        if let urlError = underlyingURLError(in: error) {
            return map(urlError: urlError)
        }

        let messages = collectedMessages(from: error)
        let combinedMessage = messages.joined(separator: " ")

        if indicatesSourceUnavailable(combinedMessage) {
            return .sourceUnavailable
        }

        return .unknown(messages.first ?? fallback)
    }

    static func fromDirectPlayFailureMessage(
        _ message: String?,
        fallback: String = directPlayFallbackMessage
    ) -> PlaybackError {
        let cleanedMessage = cleanedResponseText(message)
        guard let cleanedMessage, !cleanedMessage.isEmpty else {
            return .unknown(fallback)
        }

        if indicatesSourceUnavailable(cleanedMessage) {
            return .sourceUnavailable
        }

        return .unknown(cleanedMessage)
    }

    private static func mapDirectPlayFailure(
        statusCode: Int,
        responseText: String?,
        fallback: String
    ) -> PlaybackError {
        if statusCode == 401 {
            return .unauthorized
        }

        let cleanedResponse = cleanedResponseText(responseText)
        if statusCode == 404 || indicatesSourceUnavailable(cleanedResponse) {
            return .sourceUnavailable
        }

        if let cleanedResponse, !cleanedResponse.isEmpty {
            return .unknown(cleanedResponse)
        }

        return .unknown("\(fallback) Server returned HTTP \(statusCode).")
    }

    private static func collectedMessages(from error: Error) -> [String] {
        var messages: [String] = []
        var visited = Set<ObjectIdentifier>()
        appendMessages(from: error as NSError, to: &messages, visited: &visited)
        return messages
    }

    private static func appendMessages(
        from error: NSError,
        to messages: inout [String],
        visited: inout Set<ObjectIdentifier>
    ) {
        let identifier = ObjectIdentifier(error)
        guard visited.insert(identifier).inserted else { return }

        let candidateMessages = [
            error.localizedDescription,
            error.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
            error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String,
        ]

        for message in candidateMessages.compactMap({ cleanedResponseText($0) }) where !messages.contains(message) {
            messages.append(message)
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            appendMessages(from: underlyingError, to: &messages, visited: &visited)
        }
    }

    private static func underlyingURLError(in error: Error) -> URLError? {
        if let urlError = error as? URLError {
            return urlError
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLError(URLError.Code(rawValue: nsError.code), userInfo: nsError.userInfo)
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return underlyingURLError(in: underlyingError)
        }

        return nil
    }

    private static func map(urlError: URLError) -> PlaybackError {
        if serverUnreachableCodes.contains(urlError.code) {
            return .serverUnreachable
        }

        return .networkError(urlError.localizedDescription)
    }

    private static func indicatesSourceUnavailable(_ text: String?) -> Bool {
        guard let text else { return false }
        let normalizedText = text.lowercased()
        return sourceUnavailableMarkers.contains { normalizedText.contains($0) }
    }

    private static func cleanedResponseText(_ text: String?) -> String? {
        guard let text else { return nil }

        let withoutTags = text.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )

        let collapsedWhitespace = withoutTags.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsedWhitespace.isEmpty ? nil : collapsedWhitespace
    }

    private static func readPrefix(
        from bytes: URLSession.AsyncBytes,
        limit: Int
    ) async throws -> String? {
        var data = Data()
        var iterator = bytes.makeAsyncIterator()

        while data.count < limit, let byte = try await iterator.next() {
            data.append(byte)
        }

        return String(data: data, encoding: .utf8)
    }
}
