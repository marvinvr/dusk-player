import Foundation
import Testing
@testable import Dusk

@Suite("Plex connection locality")
struct PlexConnectionLocalityTests {
    private func connection(
        _ uri: String,
        address: String,
        local: Bool,
        relay: Bool = false
    ) -> PlexConnection {
        let url = URL(string: uri)!
        return PlexConnection(
            protocol: url.scheme ?? "https", address: address, port: url.port ?? 32400,
            uri: uri, local: local, relay: relay, iPv6: address.contains(":")
        )
    }

    @Test func plexFlaggedLocalIsLocal() {
        let lan = connection("https://192-168-1-10.abc.plex.direct:32400", address: "192.168.1.10", local: true)
        #expect(lan.isOnLocalNetwork)
        #expect(lan.sortPriority == 0)
    }

    @Test func unflaggedPrivateAddressIsLocal() {
        let custom = connection("http://10.0.0.5:32400", address: "10.0.0.5", local: false)
        #expect(custom.isOnLocalNetwork)
        #expect(custom.sortPriority == 0)
    }

    @Test func plexDirectHostEncodingAPrivateIPIsLocal() {
        let custom = connection("https://172-20-0-3.abc.plex.direct:32400", address: "plex.example.com", local: false)
        #expect(custom.isOnLocalNetwork)
    }

    @Test func publicAddressIsRemote() {
        let wan = connection("https://84-73-1-2.abc.plex.direct:32400", address: "84.73.1.2", local: false)
        #expect(!wan.isOnLocalNetwork)
        #expect(wan.sortPriority == 1)
    }

    @Test func relayIsNeverLocal() {
        let relay = connection("https://10-0-0-5.abc.plex.direct:8443", address: "10.0.0.5", local: true, relay: true)
        #expect(!relay.isOnLocalNetwork)
        #expect(relay.sortPriority == 2)
    }

    @Test func privateRanges() {
        for address in ["10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.0.1", "127.0.0.1", "169.254.1.1", "fd12::1", "[fc00::5]", "::1"] {
            #expect(PlexConnection.isPrivateAddress(address), "\(address)")
        }
        for address in ["172.32.0.1", "100.64.0.1", "8.8.8.8", "2001:db8::1", "plex.example.com"] {
            #expect(!PlexConnection.isPrivateAddress(address), "\(address)")
        }
    }

    @Test func plexDirectDecoding() {
        #expect(PlexConnection.plexDirectIPAddress(in: "192-168-1-10.abc.plex.direct") == "192.168.1.10")
        #expect(PlexConnection.plexDirectIPAddress(in: "fd00-0-0-0-0-0-0-1.abc.plex.direct") == "fd00:0:0:0:0:0:0:1")
        #expect(PlexConnection.plexDirectIPAddress(in: "plex.example.com") == nil)
    }

    @Test func dockerBridgeAddressIsKeptButTriedAfterOtherLocalAddresses() throws {
        let json = """
        {"name":"Home","clientIdentifier":"m","owned":true,"presence":true,"connections":[
          {"protocol":"https","address":"172.18.0.2","port":32400,"uri":"https://172-18-0-2.abc.plex.direct:32400","local":true,"relay":false},
          {"protocol":"https","address":"84.73.1.2","port":32400,"uri":"https://84-73-1-2.abc.plex.direct:32400","local":false,"relay":false},
          {"protocol":"https","address":"192.168.1.10","port":32400,"uri":"https://192-168-1-10.abc.plex.direct:32400","local":true,"relay":false}
        ]}
        """
        let server = try JSONDecoder().decode(PlexServer.self, from: Data(json.utf8))
        #expect(server.sortedConnections.map(\.address) == ["192.168.1.10", "172.18.0.2", "84.73.1.2"])
        #expect(!server.connections[0].isKnownUnreachableAddress)
    }

    @Test func unknownLocalityIsNeitherLocalNorRemote() {
        let restored = PlexServerConnection(
            serverID: "m", name: "Home", owned: true, sourceTitle: nil,
            baseURL: URL(string: "http://192.168.1.10:32400")!, token: "t", connection: nil
        )
        #expect(!restored.isLocal)
        #expect(!restored.isRemote)
    }
}
