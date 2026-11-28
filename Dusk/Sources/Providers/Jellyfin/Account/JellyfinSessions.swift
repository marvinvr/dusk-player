import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The URL sessions every Jellyfin client in this build sends through, with
/// the same budgets as Plex's (`PlexClient`): 15 s per request on the shared
/// session, a short ephemeral one for sign-in and probes. Redirects to another
/// origin are refused, so the `Authorization` header and an `ApiKey` never
/// follow one.
final class JellyfinSessions: Sendable {
    let shared: URLSession
    let probe: URLSession

    static let standard = JellyfinSessions()

    /// - Parameter urlProtocolClasses: Tests only: serves every request.
    init(urlProtocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.waitsForConnectivity = false
        probeConfig.timeoutIntervalForRequest = 8
        probeConfig.timeoutIntervalForResource = 15
        probeConfig.urlCache = nil
        if let urlProtocolClasses {
            config.protocolClasses = urlProtocolClasses
            probeConfig.protocolClasses = urlProtocolClasses
        }
        shared = URLSession(configuration: config, delegate: JellyfinSessionDelegate(), delegateQueue: nil)
        probe = URLSession(configuration: probeConfig, delegate: JellyfinSessionDelegate(), delegateQueue: nil)
    }

    var sharedTransport: any JellyfinTransport { JellyfinURLSessionTransport(session: shared) }
    var probeTransport: any JellyfinTransport { JellyfinURLSessionTransport(session: probe) }
}

/// Follows a redirect only within the same origin.
private final class JellyfinSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let target = request.url,
              TransportSecurity.sameOrigin(original, target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

extension JellyfinClientIdentity {
    /// How Dusk introduces itself with `deviceID`: the device's name (what the
    /// dashboard and the Quick Connect approval show) and the app version.
    @MainActor
    static func dusk(deviceID: String) -> JellyfinClientIdentity {
        JellyfinClientIdentity(device: deviceName, deviceID: deviceID, version: appVersion)
    }

    @MainActor
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName?.nilIfEmpty ?? "Mac"
        #else
        UIDevice.current.name.nilIfEmpty ?? UIDevice.current.model
        #endif
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// A fresh `DeviceId` for a new sign-in: one token per id (03 §10.2).
    static func newDeviceID() -> String {
        UUID().uuidString.lowercased()
    }
}
