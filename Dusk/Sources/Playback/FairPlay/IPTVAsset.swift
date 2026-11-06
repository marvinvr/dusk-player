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
    static func failureMessage(for error: Error?) -> String {
        let reason = (error as NSError?)?.localizedFailureReason?.nilIfEmpty
            ?? error?.localizedDescription.nilIfEmpty
        guard let reason else { return "This channel couldn’t be played." }
        return "This channel couldn’t be played. \(reason)"
    }

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
