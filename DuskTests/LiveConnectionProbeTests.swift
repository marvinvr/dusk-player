import Foundation
import Testing
@testable import Dusk

/// Opt-in, real-network check of connection selection against a real Plex
/// account. Skipped unless the runner passes a token file:
///
///     TEST_RUNNER_DUSK_LIVE_TOKEN_FILE=/path/to/token xcodebuild test \
///       -only-testing:DuskTests/LiveConnectionProbeTests ...
///
/// Optional `TEST_RUNNER_DUSK_LIVE_AWAY=1` drops LAN and Tailscale/private
/// connections first ("away from home"). Prints one line per server; the
/// token is never printed. Leaves no session behind.
enum LiveProbeEnvironment {
    static var tokenFile: String? {
        ProcessInfo.processInfo.environment["DUSK_LIVE_TOKEN_FILE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var away: Bool {
        ProcessInfo.processInfo.environment["DUSK_LIVE_AWAY"] == "1"
    }
}

@Suite("Live connection probe", .serialized, .enabled(if: LiveProbeEnvironment.tokenFile != nil))
@MainActor
struct LiveConnectionProbeTests {
    static var tokenFile: String? { LiveProbeEnvironment.tokenFile }
    static var away: Bool { LiveProbeEnvironment.away }

    @Test func selectEveryServer() async throws {
        let token = try String(contentsOfFile: try #require(Self.tokenFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let service = PlexService()
        service.activeAccountToken = token
        let servers = try await service.discoverServers()
        var touched: [String] = []
        defer { touched.forEach(ServerPool.forget(serverID:)) }

        for discovered in servers {
            let server = Self.away ? try Self.awayCopy(of: discovered) : discovered
            touched.append(server.clientIdentifier)
            let started = Date()
            let connection = await service.pool.connect(to: server)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let state: String
            switch service.pool.state(for: server.clientIdentifier) {
            case let .connected(live): state = "CONNECTED \(live.baseURL.absoluteString)"
            case let .offline(reason): state = "OFFLINE \(reason)"
            case .unauthorized: state = "UNAUTHORIZED"
            default: state = "OTHER"
            }
            print("LIVE[\(Self.away ? "away" : "home")] \(server.name) \(server.connections.count) connections → \(state) in \(elapsed) ms")
            for connection in server.connections {
                print("LIVE    listed \(connection.uri) local=\(connection.local) relay=\(connection.relay)")
            }
            if let report = service.pool.reports[server.clientIdentifier] { print(report.text.split(separator: "\n").map { "LIVE    \($0)" }.joined(separator: "\n")) } // AFTER-ONLY
            if let connection {
                // A real request on the chosen endpoint.
                let data = try await service.rawServerRequest(path: "/library/sections", serverID: connection.serverID)
                print("LIVE    /library/sections \(data.count) bytes")
            }
        }
    }

    /// The same server with only connections that work away from home.
    private static func awayCopy(of server: PlexServer) throws -> PlexServer {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(server)) as? [String: Any]
        )
        let kept = server.connections.filter { connection in
            guard !connection.relay else { return true }
            let host = URL(string: connection.uri)?.host ?? connection.address
            let address = PlexConnection.plexDirectIPAddress(in: host) ?? host
            return !(connection.isOnLocalNetwork || connection.isOnTailnet
                || PlexConnection.isPrivateAddress(address) || PlexConnection.isTailnetAddress(address)
                || PlexConnection.isTailnetHostName(host) || PlexConnection.isSingleLabelHostName(host))
        }
        object["connections"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(kept))
        return try JSONDecoder().decode(PlexServer.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
