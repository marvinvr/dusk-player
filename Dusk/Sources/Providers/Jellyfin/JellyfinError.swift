import Foundation

/// Failures of a Jellyfin request. Descriptions never contain a URL, a token
/// or an `ApiKey` value, so they are safe to log and to show.
enum JellyfinError: Error, Equatable, Sendable, LocalizedError {
    /// The server address or a request path could not form a URL.
    case invalidURL
    /// A user-scoped or authenticated request was sent without credentials.
    case notAuthenticated
    /// `401`: the token is missing, revoked (same `DeviceId` signed in again)
    /// or wrong credentials on sign-in.
    case unauthorized
    /// `403`: the user's policy forbids this (subtitle management, collection
    /// management, downloads).
    case forbidden
    /// `404`: unknown item, an unapproved Quick Connect secret, a missing image.
    case notFound
    /// `400` with the server's message when it sent one.
    case badRequest(message: String?)
    case httpStatus(Int)
    /// The connection failed before an HTTP status arrived.
    case transport(code: Int, description: String)
    /// The body was not the JSON this request expects.
    case decoding(String)
    /// The body decoded but is not the result that was asked for. Jellyfin
    /// ignores unknown query parameters and answers `200` with a default
    /// result, so the client checks the shape it asked for
    /// (docs/jellyfin/02-jellyfin-api-mapping.md §0).
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Jellyfin server address is not valid."
        case .notAuthenticated:
            return "Not signed in to this Jellyfin server."
        case .unauthorized:
            return "The Jellyfin server rejected the sign-in. Sign in again."
        case .forbidden:
            return "This Jellyfin user is not allowed to do that."
        case .notFound:
            return "The Jellyfin server could not find that item."
        case .badRequest(let message):
            if let message, !message.isEmpty {
                return "The Jellyfin server rejected the request: \(message)"
            }
            return "The Jellyfin server rejected the request."
        case .httpStatus(let code):
            return "The Jellyfin server answered with status \(code)."
        case .transport(_, let description):
            return description
        case .decoding:
            return "The Jellyfin server sent a response Dusk could not read."
        case .unexpectedResponse:
            return "The Jellyfin server sent an unexpected response."
        }
    }

    /// Whether signing in again could fix it.
    var isAuthenticationFailure: Bool {
        self == .unauthorized || self == .notAuthenticated
    }

    static func status(_ code: Int, body: Data) -> JellyfinError {
        switch code {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 400: return .badRequest(message: serverMessage(in: body))
        default: return .httpStatus(code)
        }
    }

    /// The first line of a plain-text or `ProblemDetails` body, short and with
    /// anything that looks like a credential removed.
    static func serverMessage(in body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        var text: String?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            text = (object["detail"] as? String) ?? (object["title"] as? String) ?? (object["Message"] as? String)
        } else if let plain = String(data: body.prefix(512), encoding: .utf8),
                  !plain.contains("<") {
            text = plain
        }
        guard let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return JellyfinRedaction.redact(String(line.prefix(200)))
    }
}

/// Removes credentials from text that may be logged: `ApiKey` / `api_key`
/// query values and `Token="…"` header parameters.
enum JellyfinRedaction {
    static func redact(_ text: String) -> String {
        var result = text
        for pattern in [#"(?i)(api_?key=)[^&\s"']+"#, #"(?i)(token=")[^"]*"#, #"(?i)(token=)[^&\s"',]+"#] {
            result = result.replacingOccurrences(of: pattern, with: "$1REDACTED", options: .regularExpression)
        }
        return result
    }

    static func redact(_ url: URL) -> String {
        redact(url.absoluteString)
    }
}
