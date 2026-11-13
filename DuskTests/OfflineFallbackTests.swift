import Foundation
import Testing
@testable import Dusk

@Suite("Offline Downloads fallback")
struct OfflineFallbackTests {
    @Test func airplaneModeDoesNotTrustARestoredConnection() {
        #expect(shows(network: false, availability: .ready(offlineServerNames: [])))
    }

    @Test func exhaustedCandidatesOpenDownloads() {
        #expect(shows(availability: .unreachable(reason: "Connection refused")))
    }

    @Test func discoveryFailureWithoutServersOpensDownloads() {
        #expect(shows(availability: .unknown, completed: true, failed: true))
        #expect(!shows(availability: .unknown, completed: false, failed: true))
    }

    @Test func partialOutageKeepsOnlineContent() {
        #expect(!shows(availability: .ready(offlineServerNames: ["Unavailable"]), completed: true, failed: true))
    }

    @Test func startupAndExplicitlyDisabledServersDoNotForceDownloads() {
        #expect(!shows(availability: .unknown))
        #expect(!shows(availability: .connecting))
        #expect(!shows(availability: .allDisabled, completed: true))
    }

    @Test func noRouteTakesPriorityOverAnUnfinishedPass() {
        #expect(shows(network: false, availability: .connecting))
        #expect(shows(network: false, availability: .unknown))
    }

    @Test func recoveryClearsTheFallback() {
        #expect(shows(availability: .unreachable(reason: nil), completed: true))
        #expect(!shows(availability: .ready(offlineServerNames: []), completed: true))
    }

    @Test func tvOSAndUnauthenticatedSessionsNeverEnterDownloads() {
        #expect(!OfflineFallback.showsDownloads(
            downloadsSupported: false, sessionReady: true, networkAvailable: false,
            availability: .unreachable(reason: nil), hasCompletedPass: true, connectionFailed: true
        ))
        #expect(!OfflineFallback.showsDownloads(
            downloadsSupported: true, sessionReady: false, networkAvailable: false,
            availability: .unreachable(reason: nil), hasCompletedPass: true, connectionFailed: true
        ))
    }

    @Test func cachedIdentityRequiresAutomaticSignInAndTheCorrectCredential() {
        #expect(canRestore(primary: "owner", home: nil))
        #expect(canRestore(primary: "owner", home: "owner"))
        #expect(canRestore(primary: "owner", home: "member", remembered: true))
        #expect(!canRestore(primary: "owner", home: "member"))
        #expect(!canRestore(primary: nil, home: nil))
        #expect(!canRestore(primary: "owner", home: "member", remembered: true, automatic: false))
        #expect(!canRestore(primary: "owner", home: nil, automatic: false))
    }

    @Test func authenticationAndInvalidResponsesCannotRestoreACachedSession() {
        #expect(OfflineFallback.permitsCachedSession(after: PlexServiceError.networkError("Offline")))
        #expect(OfflineFallback.permitsCachedSession(after: PlexServiceError.httpError(statusCode: 503)))
        #expect(!OfflineFallback.permitsCachedSession(after: PlexServiceError.unauthorized))
        #expect(!OfflineFallback.permitsCachedSession(after: PlexServiceError.httpError(statusCode: 403)))
        #expect(!OfflineFallback.permitsCachedSession(after: PlexServiceError.decodingError("Invalid")))
        #expect(!OfflineFallback.permitsCachedSession(after: CancellationError()))
    }

    #if os(iOS)
    @Test @MainActor func offlineBootstrapRestoresTheProfileWithoutCompletingMigration() async throws {
        let service = PlexService(urlProtocolClasses: [OfflineBootstrapStub.self])
        defer {
            service.session.invalidateAndCancel()
            service.slowQuerySession.invalidateAndCancel()
            service.probeSession.invalidateAndCancel()
        }
        service.primaryAccountToken = "offline-test"
        service.activeAccountToken = "offline-test"
        service.primaryProfileID = "offline-owner"
        service.activeHomeUser = nil
        let defaults = UserDefaults.standard
        let automaticSignIn = defaults.object(forKey: PlexService.defaultsAutomaticHomeSignInKey)
        service.automaticHomeSignIn = true
        defer {
            if let automaticSignIn {
                defaults.set(automaticSignIn, forKey: PlexService.defaultsAutomaticHomeSignInKey)
            } else {
                defaults.removeObject(forKey: PlexService.defaultsAutomaticHomeSignInKey)
            }
        }
        let migration = UserDefaults.standard.object(forKey: PlexService.defaultsHomeMigrationCompletedKey) as? Bool
        try await service.bootstrapHomeSession()
        #expect(service.isSessionReady)
        #expect(service.isUsingOfflineHomeSession)
        #expect(service.activeProfileID == "offline-owner")
        #expect(UserDefaults.standard.object(forKey: PlexService.defaultsHomeMigrationCompletedKey) as? Bool == migration)
    }
    #endif

    @Test func aRetryKeepsDownloadsUntilAConnectionIsUsable() {
        #expect(shows(availability: .connecting, completed: true, failed: true))
        #expect(!shows(availability: .allDisabled, completed: true, failed: true))
        #expect(OfflineFallback.showsDownloads(
            downloadsSupported: true, sessionReady: true, networkAvailable: true,
            awaitingHomeValidation: true, availability: .ready(offlineServerNames: []),
            hasCompletedPass: false, connectionFailed: false
        ))
    }

    private func shows(
        network: Bool = true,
        availability: ServerAvailability,
        completed: Bool = false,
        failed: Bool = false
    ) -> Bool {
        OfflineFallback.showsDownloads(
            downloadsSupported: true, sessionReady: true, networkAvailable: network,
            availability: availability, hasCompletedPass: completed, connectionFailed: failed
        )
    }

    private func canRestore(
        primary: String?, home: String?, remembered: Bool = false, automatic: Bool = true
    ) -> Bool {
        OfflineFallback.canRestoreProfile(
            automaticSignIn: automatic, primaryProfileID: primary,
            homeProfileID: home, hasRememberedToken: remembered
        )
    }
}

private final class OfflineBootstrapStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
