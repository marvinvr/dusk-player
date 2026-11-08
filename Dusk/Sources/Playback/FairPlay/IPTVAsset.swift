import AVFoundation
import Foundation

/// How AVPlayer opens an IPTV channel. IPTV never goes through VLCKit or a
/// Plex server: the stream URL is handed to AVFoundation as is, with the
/// source's headers on every request of the asset.
enum IPTVAsset {
    static func makeAsset(for stream: IPTVPlayableChannel) -> AVURLAsset {
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty {
            // Not in the public header, but the long-standing, App Store-safe
            // way to put headers on an asset's playlist and segment requests.
            options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
        }
        if let userAgent = stream.userAgent {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        return AVURLAsset(url: stream.streamURL, options: options)
    }

    static func licenseClient(for stream: IPTVPlayableChannel) -> FairPlayLicenseClient {
        FairPlayLicenseClient(
            certificateURL: stream.drm?.certificateURL,
            licenseURL: stream.drm?.licenseURL,
            headers: stream.headers,
            userAgent: stream.userAgent
        )
    }

    /// AVFoundation's own wording for a failed IPTV item, without the Plex
    /// direct-play phrasing the library path uses.
    static func failureMessage(for error: Error?, isCatchUp: Bool = false) -> String {
        let reason = (error as NSError?)?.localizedFailureReason?.nilIfEmpty
            ?? error?.localizedDescription.nilIfEmpty
        let summary = isCatchUp ? "This program couldn’t be played." : "This channel couldn’t be played."
        guard let reason else { return summary }
        return "\(summary) \(reason)"
    }

    /// A catch-up item that failed: asks the server why. AVFoundation only
    /// says "not found", while a source usually knows the replay was never
    /// published. Runs only after a failure, so a replay that works never
    /// costs a second request. Nil when the answer explains nothing.
    static func catchUpRefusal(for stream: IPTVPlayableChannel) async -> String? {
        var request = URLRequest(url: stream.streamURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in stream.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let userAgent = stream.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        // An explanation is a line of text; never read a whole stream for one.
        var body = Data()
        if !(200...299).contains(http.statusCode), http.isPlainTextResponse {
            do {
                for try await byte in bytes.prefix(catchUpRefusalMaxLength + 1) { body.append(byte) }
            } catch {
                body = Data()
            }
        }
        bytes.task.cancel()
        return catchUpRefusalMessage(status: http.statusCode, body: String(decoding: body, as: UTF8.self))
    }

    /// What the viewer reads for a refused catch-up request, or nil when the
    /// status does not explain the failure. The server's own sentence wins when
    /// it is one: it may know more than the status does.
    static func catchUpRefusalMessage(status: Int, body: String?) -> String? {
        let fallback: String
        switch status {
        case 404, 410: fallback = "No replay is available for this program."
        case 401, 403: fallback = "The replay of this program was refused."
        case 400..<600: fallback = "The replay of this program couldn’t be loaded (HTTP \(status))."
        default: return nil
        }
        guard let text = body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              text.count <= catchUpRefusalMaxLength,
              !text.contains("\n"), !text.hasPrefix("<"), !text.hasPrefix("{") else {
            return fallback
        }
        return text.hasSuffix(".") ? text : "\(text)."
    }

    private static let catchUpRefusalMaxLength = 200

    /// Strips query and credentials before a stream URL reaches the log.
    static func sanitizedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.host ?? "iptv"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? (url.host ?? "iptv")
    }
}

private extension HTTPURLResponse {
    var isPlainTextResponse: Bool {
        (value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("text/plain")
    }
}
