import Foundation
import UIKit

/// Fire-and-forget event reporting to the self-hosted Rybbit instance at
/// `stats.marvinvr.ch`, the same one the website already uses (a separate
/// Rybbit "site" so app and web numbers never mix).
///
/// The design constraints are deliberate and load-bearing for the privacy
/// policy, so they should survive future edits:
///
/// - **Fixed vocabulary.** Only `AnalyticsEventName` cases can be reported.
/// - **No queue, no buffer, no retry.** A failed send is dropped and forgotten.
///   A persistent outbox would slowly turn into a device history on disk.
/// - **We supply `user_id` ourselves**, a local random string kept in
///   UserDefaults rather than the Keychain so deleting the app genuinely resets
///   it, and rotated whenever the user turns reporting off. Supplying it means
///   Rybbit never has to fall back to its default identity, which is a hash of
///   IP and User-Agent.
/// - **Nothing Plex-derived is ever reported.** No titles, servers, libraries,
///   search terms, or playback state. See `docs/analytics.md`.
/// - **Nothing is ever surfaced to the user.** No error state, no spinner, no
///   log. A failure to report is invisible by design.
/// - **Debug builds report nothing**, so development never pollutes counters.
@MainActor
@Observable
final class AnalyticsClient {
    private enum Keys {
        static let installID = "analyticsInstallID"
        static let lastOpenDay = "analyticsLastOpenDay"
    }

    private enum Configuration {
        static let endpoint = URL(string: "https://stats.marvinvr.ch/api/track")!
        static let siteID = "e76b9d7b1558"

        /// Optional. Rybbit accepts events from any origin without one, but a
        /// key (Rybbit site Settings → API Key) bypasses bot detection, which
        /// is worth having for a client whose User-Agent is not a browser.
        static let apiKey = ""

        /// Rybbit is page-shaped. Events carry a synthetic host so the app's
        /// traffic is attributable in dashboards that group by hostname.
        static let hostname = "app.getdusk.app"
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
        guard isActive else { return }
        guard let body = payload(for: event) else { return }

        Task.detached(priority: .background) {
            await Self.post(body)
        }
    }

    /// Reporting only happens in release builds, with the user's consent.
    private var isActive: Bool {
        #if DEBUG
        false
        #else
        preferences.analyticsEnabled
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
        // Rybbit's own dashboards (users, sessions, retention, countries) are
        // driven by pageviews, so the daily heartbeat is sent as one. Everything
        // else is a custom event.
        let isPageview = event.name.isPageview

        let body = Payload(
            siteID: Configuration.siteID,
            type: isPageview ? "pageview" : "custom_event",
            eventName: isPageview ? nil : event.name.rawValue,
            properties: encodedProperties(for: event),
            userID: installID,
            hostname: Configuration.hostname,
            pathname: event.name.path,
            userAgent: Self.userAgent,
            language: Self.language
        )

        return try? JSONEncoder().encode(body)
    }

    /// Rybbit takes `properties` as a JSON-encoded *string*, and only supports
    /// string and number values with no nesting.
    private func encodedProperties(for event: AnalyticsEvent) -> String? {
        var properties = event.properties
        properties["app_version"] = .string(Self.appVersion)
        properties["platform"] = .string(Self.platform)

        guard let data = try? JSONEncoder().encode(properties) else { return nil }
        return String(data: data, encoding: .utf8)
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

    /// Sent explicitly so Rybbit is not left parsing URLSession's default
    /// CFNetwork string, which reads as neither a browser nor a known client.
    private static let userAgent: String = {
        let system = UIDevice.current.systemName
        let version = UIDevice.current.systemVersion
        return "Dusk/\(appVersion) (\(system) \(version))"
    }()

    private static let language: String = {
        Locale.current.language.languageCode?.identifier ?? "en"
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

    private nonisolated static func post(_ body: Data) async {
        var request = URLRequest(url: Configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !Configuration.apiKey.isEmpty {
            request.setValue("Bearer \(Configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 10
        // Nothing reads the response. Every failure mode — offline, rate
        // limited, rejected, server down — ends the same way: the event is
        // gone. That is the whole retry policy.
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Wire format

    private struct Payload: Encodable {
        let siteID: String
        let type: String
        let eventName: String?
        let properties: String?
        let userID: String
        let hostname: String
        let pathname: String
        let userAgent: String
        let language: String

        enum CodingKeys: String, CodingKey {
            case siteID = "site_id"
            case type
            case eventName = "event_name"
            case properties
            case userID = "user_id"
            case hostname
            case pathname
            case userAgent = "user_agent"
            case language
        }
    }
}
