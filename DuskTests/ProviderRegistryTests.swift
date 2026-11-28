import Foundation
import Testing
@testable import Dusk

/// P0-06: the pool stores a provider on every session it records. Nothing
/// routes through it yet, so these only pin what it is built from.
@Suite("Provider registry")
@MainActor
struct ProviderRegistryTests {
    @Test func recordedSessionsCarryTheirServersPlexProvider() throws {
        // Every request is intercepted; adopting a session sends none.
        let serverID = "provider-registry-\(UUID().uuidString)"
        let service = MediaService(urlProtocolClasses: [SelectionStub.self])
        let server = try JSONDecoder().decode(AccountServer.self, from: JSONSerialization.data(withJSONObject: [
            "name": "Shared", "clientIdentifier": serverID, "owned": false,
            "sourceTitle": "Alex", "productVersion": "1.40.0", "connections": [],
        ]))
        defer {
            ServerPool.forget(serverID: serverID)
            service.session.invalidateAndCancel()
            service.slowQuerySession.invalidateAndCancel()
            service.probeSession.invalidateAndCancel()
            service.bootstrapSession.invalidateAndCancel()
        }
        service.pool.adopt(server: server, baseURL: URL(string: "https://provider.invalid")!, token: "test-token", connection: nil)

        let session = try #require(service.pool.connection(for: serverID))
        let provider = try #require(session.provider as? PlexServerProvider)
        #expect(provider.descriptor == ServerDescriptor(
            id: serverID, name: "Shared", kind: .plex, version: "1.40.0", ownerLabel: "Alex"
        ))
        #expect(provider.client === service.client)
        #expect(service.providers.factory(for: .plex) != nil)
        #expect(service.providers.factory(for: .jellyfin) is JellyfinProviderFactory)
    }

    @Test func theProviderIsNotPartOfSessionEquality() {
        let service = MediaService(urlProtocolClasses: [SelectionStub.self])
        defer {
            service.session.invalidateAndCancel()
            service.slowQuerySession.invalidateAndCancel()
            service.probeSession.invalidateAndCancel()
            service.bootstrapSession.invalidateAndCancel()
        }
        let bare = ServerSession(
            serverID: "m", name: "Home", owned: true, sourceTitle: nil,
            baseURL: URL(string: "https://home.invalid")!, token: "t", connection: nil
        )
        var withProvider = bare
        withProvider.provider = PlexProviderFactory(client: service.client).makeServerProvider(
            ServerSessionSeed(serverID: "m", name: "Home", version: nil, owned: true, sourceTitle: nil)
        )
        #expect(bare == withProvider)
        #expect(bare.hashValue == withProvider.hashValue)
        var moved = withProvider
        moved.isVerified = false
        #expect(moved != withProvider)
    }
}
