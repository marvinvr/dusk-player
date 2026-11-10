import Foundation
import OSLog

let plexConnectionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexConnection"
)

/// How an endpoint reaches the server, best first.
enum ConnectionLocality: Int, Sendable, Comparable, Codable {
    /// The LAN: plex.tv's `local` flag or a private address.
    case local = 0
    /// A Tailscale address, a `*.ts.net` name or a single-label private name
    /// ("storage"): not the LAN, but not the public internet either.
    case tailnet = 1
    /// A direct public connection.
    case remote = 2
    /// Plex's relay. Bandwidth-capped, so always the last resort.
    case relay = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .local: "LAN"
        case .tailnet: "Tailscale / private name"
        case .remote: "Remote"
        case .relay: "Relay"
        }
    }
}

/// Where a candidate URL came from.
enum ConnectionCandidateSource: String, Sendable, Codable {
    /// A connection exactly as plex.tv resources lists it.
    case plex
    /// The HTTPS form of a public `http://` connection (custom URL behind a
    /// TLS reverse proxy).
    case httpsUpgrade
    /// The raw-address `http://` form of an HTTPS plex.direct connection, for
    /// networks whose DNS refuses plex.direct (rebinding protection).
    case httpFallback
    /// The endpoint this device used last, when plex.tv no longer lists it.
    case lastKnownGood

    var label: String {
        switch self {
        case .plex: "plex.tv"
        case .httpsUpgrade: "https upgrade"
        case .httpFallback: "http fallback"
        case .lastKnownGood: "last used"
        }
    }
}

/// One endpoint we could reach a server at.
struct ConnectionCandidate: Sendable, Hashable {
    let baseURL: URL
    let connection: PlexConnection
    let source: ConnectionCandidateSource

    init(baseURL: URL, connection: PlexConnection, source: ConnectionCandidateSource = .plex) {
        self.baseURL = baseURL
        self.connection = connection
        self.source = source
    }

    var isSecure: Bool { baseURL.scheme?.lowercased() == "https" }

    var locality: ConnectionLocality {
        if connection.relay { return .relay }
        let host = baseURL.host ?? ""
        let address = PlexConnection.plexDirectIPAddress(in: host) ?? host
        if connection.isOnLocalNetwork || PlexConnection.isPrivateAddress(address) || host.hasSuffix(".local") {
            return .local
        }
        if connection.isOnTailnet || PlexConnection.isTailnetAddress(address)
            || PlexConnection.isTailnetHostName(host) || PlexConnection.isSingleLabelHostName(host) {
            return .tailnet
        }
        return .remote
    }

    /// The ranking class. Lower wins; latency only breaks ties inside a class.
    ///
    /// 1. Direct before relay (the relay is bandwidth-capped).
    /// 2. HTTPS before HTTP: never trade a working HTTPS endpoint for HTTP.
    /// 3. LAN, then tailnet / private name, then remote.
    /// 4. A Docker-bridge-looking LAN address after any other LAN address.
    var rank: Rank {
        Rank(
            relay: connection.relay,
            insecure: !isSecure,
            locality: locality == .relay ? ConnectionLocality.remote.rawValue : locality.rawValue,
            bridge: connection.isLikelyContainerBridgeAddress
        )
    }

    struct Rank: Comparable, Hashable, Sendable {
        let relay: Bool
        let insecure: Bool
        let locality: Int
        let bridge: Bool

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.relay ? 1 : 0, lhs.insecure ? 1 : 0, lhs.locality, lhs.bridge ? 1 : 0)
                < (rhs.relay ? 1 : 0, rhs.insecure ? 1 : 0, rhs.locality, rhs.bridge ? 1 : 0)
        }
    }

    /// Per-candidate budget: a LAN answers in milliseconds or not at all, the
    /// relay is allowed to be slow.
    var timeout: TimeInterval {
        switch locality {
        case .local: 5
        case .tailnet: 8
        case .remote: 10
        case .relay: 12
        }
    }
}

/// Outcome of selecting a server's connection.
enum ConnectionResolution: Sendable {
    case connected(URL, PlexConnection)
    case unauthorized
    case failed(String)
}

/// What one candidate did during a selection, for the diagnostics screen.
enum ConnectionProbeOutcome: Sendable, Equatable {
    /// `/identity` named this server and the token was accepted.
    case reachable(latency: TimeInterval)
    /// Answered, but as a different (or no) Plex server.
    case wrongServer(String?)
    case unauthorized
    case failed(String)
    /// Still running when a better candidate was committed.
    case skipped

    var isReachable: Bool {
        if case .reachable = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case let .reachable(latency): "OK · \(Int((latency * 1000).rounded())) ms"
        case let .wrongServer(found): found.map { "Different server (\($0.prefix(8))…)" } ?? "Not a Plex server"
        case .unauthorized: "Token rejected (401)"
        case let .failed(reason): reason
        case .skipped: "No answer yet when another was chosen"
        }
    }
}

/// A record of one selection for one server.
struct ConnectionReport: Sendable, Identifiable {
    struct Entry: Sendable, Identifiable {
        let id: Int
        let url: URL
        let locality: ConnectionLocality
        let isSecure: Bool
        let source: ConnectionCandidateSource
        var outcome: ConnectionProbeOutcome
        var isChosen: Bool
    }

    let id = UUID()
    let serverID: String
    let serverName: String
    let trigger: String
    let startedAt: Date
    var duration: TimeInterval
    var entries: [Entry]
    var chosenURL: URL?
    var result: String

    /// Plain text for "Copy Report". URLs never carry the token.
    var text: String {
        var lines = [
            "\(serverName) (\(serverID.prefix(8))…)",
            "Trigger: \(trigger) · \(startedAt.formatted(date: .abbreviated, time: .standard)) · \(Int((duration * 1000).rounded())) ms",
            "Result: \(result)",
        ]
        for entry in entries {
            lines.append(
                "\(entry.isChosen ? "→" : " ") \(entry.url.absoluteString) [\(entry.locality.label), \(entry.isSecure ? "https" : "http"), \(entry.source.label)] \(entry.outcome.summary)"
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// Picks the best working connection for one Plex server.
///
/// Every candidate is probed concurrently: `GET /identity` must answer with the
/// expected `machineIdentifier` (so a wrong host, a captive portal or another
/// server on a recycled address can never win), then `GET /library/sections`
/// must accept the token. Among the candidates that pass, the lowest
/// `ConnectionCandidate.rank` wins, latency breaking ties.
///
/// The race commits as soon as no still-running candidate could outrank the
/// best one, or `grace` after the first success — so a hung LAN or Docker
/// bridge address never holds up a working remote one when we are away, while
/// a reachable better candidate still wins when we are home.
enum ConnectionSelector {
    static let defaultGrace: Duration = .milliseconds(1500)

    struct Selection: Sendable {
        let resolution: ConnectionResolution
        let report: ConnectionReport
    }

    static func select(
        candidates: [ConnectionCandidate],
        serverID: String,
        serverName: String,
        token: String,
        headers: [String: String],
        session: URLSession,
        trigger: String,
        grace: Duration = defaultGrace,
        waitForAll: Bool = false
    ) async -> Selection {
        let startedAt = Date()
        let clock = ContinuousClock()
        let start = clock.now
        var entries = candidates.enumerated().map { index, candidate in
            ConnectionReport.Entry(
                id: index, url: candidate.baseURL, locality: candidate.locality,
                isSecure: candidate.isSecure, source: candidate.source,
                outcome: .skipped, isChosen: false
            )
        }

        func finish(_ resolution: ConnectionResolution, chosen: Int?) -> Selection {
            if let chosen { entries[chosen].isChosen = true }
            let result: String
            switch resolution {
            case let .connected(url, _): result = "Connected via \(url.absoluteString)"
            case .unauthorized: result = "Server rejected the token"
            case let .failed(reason): result = "Nothing reachable: \(reason)"
            }
            let elapsed = clock.now - start
            let report = ConnectionReport(
                serverID: serverID, serverName: serverName, trigger: trigger, startedAt: startedAt,
                duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                entries: entries, chosenURL: chosen.map { candidates[$0].baseURL }, result: result
            )
            log(report)
            return Selection(resolution: resolution, report: report)
        }

        guard !candidates.isEmpty else {
            return finish(.failed("No connections for \(serverName)"), chosen: nil)
        }

        let authorized = headers.merging(["X-Plex-Token": token]) { _, new in new }

        return await withTaskGroup(of: Event.self) { group -> Selection in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    .probe(index, await probe(candidate, serverID: serverID, headers: authorized, session: session))
                }
            }

            var pending = Set(candidates.indices)
            var best: (index: Int, latency: TimeInterval)?
            var graceStarted = false
            var committed: Int?

            func beats(_ index: Int, _ latency: TimeInterval, _ other: (index: Int, latency: TimeInterval)) -> Bool {
                let lhs = candidates[index].rank, rhs = candidates[other.index].rank
                if lhs != rhs { return lhs < rhs }
                return latency < other.latency
            }

            func bestIsUnbeatable() -> Bool {
                guard let best else { return false }
                let bestRank = candidates[best.index].rank
                return !pending.contains { candidates[$0].rank < bestRank }
            }

            for await event in group {
                // Drain every child (cancelled ones included) before leaving.
                guard committed == nil else { continue }
                switch event {
                case let .probe(index, outcome):
                    pending.remove(index)
                    entries[index].outcome = outcome
                    if case let .reachable(latency) = outcome {
                        if best.map({ beats(index, latency, $0) }) ?? true {
                            best = (index, latency)
                        }
                        if !waitForAll, !graceStarted, !bestIsUnbeatable() {
                            graceStarted = true
                            group.addTask {
                                try? await Task.sleep(for: grace)
                                return .graceElapsed
                            }
                        }
                    }
                    if !waitForAll, bestIsUnbeatable() {
                        committed = best?.index
                        group.cancelAll()
                    }
                case .graceElapsed:
                    if let best {
                        committed = best.index
                        group.cancelAll()
                    }
                }
                if pending.isEmpty { group.cancelAll() }
            }

            // Whatever was still running when we committed did not get to finish.
            for index in pending { entries[index].outcome = .skipped }

            if let chosen = committed ?? best?.index {
                let candidate = candidates[chosen]
                return finish(.connected(candidate.baseURL, candidate.connection), chosen: chosen)
            }
            if entries.contains(where: { $0.outcome == .unauthorized }) {
                return finish(.unauthorized, chosen: nil)
            }
            let reason = entries.lazy.compactMap { entry -> String? in
                if case let .failed(reason) = entry.outcome { return reason }
                return nil
            }.first ?? "Could not connect to \(serverName)"
            return finish(.failed(reason), chosen: nil)
        }
    }

    /// `/identity` (must name `serverID`) then `/library/sections` (must accept
    /// the token). The token travels on both — HTTP included, see
    /// `PlexTransportSecurity`; redirects to another host never get it.
    ///
    /// `@inline(never)`: this runs as a task group child and has a `do`/`catch`,
    /// the shape Swift 6.4 `-O` miscompiles (see `Result.capturing`).
    @inline(never)
    static func probe(
        _ candidate: ConnectionCandidate,
        serverID: String,
        headers: [String: String],
        session: URLSession,
        timeout: TimeInterval? = nil
    ) async -> ConnectionProbeOutcome {
        guard let identityURL = url(candidate.baseURL, "/identity"),
              let sectionsURL = url(candidate.baseURL, "/library/sections") else {
            return .failed("Invalid URL")
        }
        do {
            let clock = ContinuousClock()
            let started = clock.now
            let (data, response) = try await session.data(for: request(identityURL, candidate, headers, timeout))
            let elapsed = clock.now - started
            guard let http = response as? HTTPURLResponse else { return .failed("Invalid response") }
            if let moved = redirectedElsewhere(http, from: identityURL) { return .failed(moved) }
            switch http.statusCode {
            case 200...299: break
            case 401: return .unauthorized
            default: return .failed("HTTP \(http.statusCode)")
            }
            let found = identityMachineIdentifier(in: data)
            guard found == serverID else { return .wrongServer(found) }

            let (_, sectionsResponse) = try await session.data(for: request(sectionsURL, candidate, headers, timeout))
            guard let sectionsHTTP = sectionsResponse as? HTTPURLResponse else { return .failed("Invalid response") }
            if let moved = redirectedElsewhere(sectionsHTTP, from: sectionsURL) { return .failed(moved) }
            switch sectionsHTTP.statusCode {
            case 200...299:
                return .reachable(
                    latency: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                )
            case 401: return .unauthorized
            default: return .failed("HTTP \(sectionsHTTP.statusCode)")
            }
        } catch is CancellationError {
            return .skipped
        } catch let error as URLError where error.code == .cancelled {
            return .skipped
        } catch let error as URLError {
            return .failed(describe(error))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A candidate that only answers by redirecting (http → https on a reverse
    /// proxy) is not itself the endpoint: its target is a candidate of its own.
    /// A refused cross-host redirect lands here as the bare 3xx.
    private static func redirectedElsewhere(_ response: HTTPURLResponse, from requested: URL) -> String? {
        if (300...399).contains(response.statusCode) {
            let location = response.value(forHTTPHeaderField: "Location") ?? "another URL"
            return "Redirects to \(location)"
        }
        if let answered = response.url, !PlexTransportSecurity.sameOrigin(answered, requested) {
            return "Redirects to \(answered.scheme ?? "")://\(answered.host ?? "")"
        }
        return nil
    }

    private static func request(
        _ url: URL, _ candidate: ConnectionCandidate, _ headers: [String: String], _ timeout: TimeInterval?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout ?? candidate.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func url(_ baseURL: URL, _ path: String) -> URL? {
        let base = baseURL.absoluteString
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URLComponents(string: trimmed + path)?.url
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "Timed out"
        case .cannotFindHost, .dnsLookupFailed: "Host not found (DNS)"
        case .cannotConnectToHost: "Connection refused"
        case .notConnectedToInternet: "Offline / blocked (Local Network permission?)"
        case .networkConnectionLost: "Connection lost"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            "TLS error (\(error.code.rawValue))"
        case .appTransportSecurityRequiresSecureConnection: "Blocked by App Transport Security"
        default: "\(error.localizedDescription) (\(error.code.rawValue))"
        }
    }

    private static func log(_ report: ConnectionReport) {
        plexConnectionLogger.notice("\(report.text, privacy: .public)")
    }

    /// `MediaContainer.machineIdentifier` from a JSON or XML `/identity` body.
    static func identityMachineIdentifier(in data: Data) -> String? {
        struct Identity: Decodable {
            struct Container: Decodable { let machineIdentifier: String? }
            let MediaContainer: Container
        }
        if let identity = try? JSONDecoder().decode(Identity.self, from: data) {
            return identity.MediaContainer.machineIdentifier?.nilIfEmpty
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: "<MediaContainer") != nil,
              let match = text.firstMatch(of: /machineIdentifier="([^"]+)"/) else { return nil }
        return String(match.1)
    }

    private enum Event: Sendable {
        case probe(Int, ConnectionProbeOutcome)
        case graceElapsed
    }
}
