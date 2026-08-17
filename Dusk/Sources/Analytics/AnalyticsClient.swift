import Foundation
import UIKit

/// Fire-and-forget event reporting to Tally, the self-hosted collector.
///
/// The design constraints are deliberate and load-bearing for the privacy
/// policy, so they should survive future edits:
///
/// - **Fixed vocabulary.** Only `AnalyticsEventName` cases can be reported.
/// - **No queue, no buffer, no retry.** A failed send is dropped and forgotten.
///   A persistent outbox would slowly turn into a device history on disk.
/// - **The identifier is a local random string**, kept in UserDefaults rather
///   than the Keychain so deleting the app genuinely resets it, and rotated
///   whenever the user turns reporting off.
/// - **Nothing Plex-derived is ever reported.** No titles, servers, libraries,
///   search terms, or playback state. See `docs/analytics.md`.
/// - **Debug builds report nothing**, so development never pollutes counters.
@MainActor
@Observable
final class AnalyticsClient {
    private enum Keys {
        static let installID = "analyticsInstallID"
        static let lastOpenDay = "analyticsLastOpenDay"
    }

    /// Deployment configuration. Both values must be filled in before a release
    /// build ships; while either is empty the client reports nothing at all, so
    /// an unconfigured build is silent rather than pointed at the wrong host.
    private enum Configuration {
        static let endpoint = "https://metrics.getdusk.app/v1/events"
        static let writeKey = ""

        static var resolved: (url: URL, key: String)? {
            guard !writeKey.isEmpty, let url = URL(string: endpoint) else { return nil }
            return (url, writeKey)
        }
    }

    private let preferences: UserPreferences
    private let defaults: UserDefaults

    init(preferences: UserPreferences, defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.defaults = defaults
    }

    // MARK: - Reporting

    /// Counts today as an active day for this device, at most once per calendar
    /// day. Safe to call on every launch and every foreground.
    func recordAppOpenedIfNeeded(now: Date = .now) {
        guard isActive else { return }

        let day = Self.dayKey(for: now)
        guard defaults.string(forKey: Keys.lastOpenDay) != day else { return }

        defaults.set(day, forKey: Keys.lastOpenDay)
        record(AnalyticsEvent(.appOpened))
    }

    func record(_ event: AnalyticsEvent) {
        guard isActive, let (url, key) = Configuration.resolved else { return }
        guard let body = payload(for: event) else { return }

        Task.detached(priority: .background) {
            await Self.post(body, to: url, key: key)
        }
    }

    /// Reporting only happens in release builds, with the user's consent, and
    /// once a real endpoint has been configured. An unconfigured build stays
    /// completely silent instead of aiming at a placeholder host.
    private var isActive: Bool {
        #if DEBUG
        false
        #else
        preferences.analyticsEnabled && Configuration.resolved != nil
        #endif
    }

    /// Called when the user flips the Settings toggle. Turning reporting off
    /// discards the identifier, so switching it back on later starts a new one
    /// that cannot be joined to anything sent before.
    func reportingPreferenceDidChange() {
        guard !preferences.analyticsEnabled else { return }
        defaults.removeObject(forKey: Keys.installID)
        defaults.removeObject(forKey: Keys.lastOpenDay)
    }

    // MARK: - Payload

    private func payload(for event: AnalyticsEvent) -> Data? {
        let body = Payload(
            schema: 1,
            installID: installID,
            appVersion: Self.appVersion,
            platform: Self.platform,
            events: [
                EventPayload(
                    name: event.name.rawValue,
                    at: Date.now.ISO8601Format(),
                    props: event.properties.isEmpty ? nil : event.properties
                )
            ]
        )

        return try? JSONEncoder().encode(body)
    }

    private var installID: String {
        if let existing = defaults.string(forKey: Keys.installID) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Keys.installID)
        return generated
    }

    // MARK: - Environment

    private static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }()

    private static let platform: String = {
        #if os(tvOS)
        return "tvos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }()

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    // MARK: - Transport

    private nonisolated static func post(_ body: Data, to url: URL, key: String) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Tally-Key")
        request.httpBody = body
        request.timeoutInterval = 10
        // Nothing reads the response. Every failure mode — offline, rate
        // limited, rejected, server down — ends the same way: the event is
        // gone. That is the whole retry policy.
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Wire format

    private struct Payload: Encodable {
        let schema: Int
        let installID: String
        let appVersion: String
        let platform: String
        let events: [EventPayload]

        enum CodingKeys: String, CodingKey {
            case schema
            case installID = "install_id"
            case appVersion = "app_version"
            case platform
            case events
        }
    }

    private struct EventPayload: Encodable {
        let name: String
        let at: String
        let props: [String: AnalyticsValue]?
    }
}
