import Foundation

/// One candidate endpoint for reaching a server, in priority order.
struct ConnectionCandidate: Sendable {
    let baseURL: URL
    let probeURL: URL
    let connection: PlexConnection
}

/// Outcome of racing every candidate of a single server.
enum ConnectionResolution: Sendable {
    case connected(URL, PlexConnection)
    case unauthorized
    case failed(String)
}

/// The connection race for one Plex server, with no session state of its own.
///
/// Lifted verbatim out of `PlexService+Servers` so several servers can be
/// probed in parallel without each race reaching into the shared service. The
/// behavior is deliberately unchanged: same ordering, same grace window, same
/// `/identity` + `/library/sections` pair.
enum ServerProbe {
    /// How long, after the first connection succeeds, we keep waiting for a
    /// still-pending higher-priority connection (e.g. the LAN address) to also
    /// come back before committing to the best success we already have. Bounds
    /// the classic "off-network, local address hangs" stall while still letting
    /// a reachable local connection win the race when we're actually home.
    static let connectionPreferenceGrace: Duration = .milliseconds(1500)

    /// A prepared, Sendable unit of work for one candidate probe. The requests
    /// are built by the caller (they need the session's Plex headers) but carry
    /// no actor state, so the actual networking can fan out across a task group.
    struct Plan: Sendable {
        let index: Int
        let baseURL: URL
        let connection: PlexConnection
        let probeRequest: URLRequest
        let validationRequest: URLRequest
    }

    static func makePlans(candidates: [ConnectionCandidate], headers: [String: String]) -> [Plan] {
        candidates.enumerated().compactMap { index, candidate -> Plan? in
            let timeout: TimeInterval = candidate.connection.local ? 20 : 8

            var probeRequest = URLRequest(url: candidate.probeURL)
            probeRequest.httpMethod = "GET"
            probeRequest.timeoutInterval = timeout
            apply(headers, to: &probeRequest)

            guard let validationURL = validationURL(for: candidate.baseURL) else {
                return nil
            }
            var validationRequest = URLRequest(url: validationURL)
            validationRequest.httpMethod = "GET"
            validationRequest.timeoutInterval = timeout
            validationRequest.cachePolicy = .reloadIgnoringLocalCacheData
            apply(headers, to: &validationRequest)

            return Plan(
                index: index,
                baseURL: candidate.baseURL,
                connection: candidate.connection,
                probeRequest: probeRequest,
                validationRequest: validationRequest
            )
        }
    }

    /// Probes every candidate connection concurrently and returns the working
    /// one with the highest priority (earliest in the sorted candidate list).
    ///
    /// The race is priority-preserving, not first-past-the-post: a candidate is
    /// only committed once no higher-priority candidate can still win — either
    /// because they have all resolved, or because the preference grace elapsed
    /// after the first success. This keeps local playback preferred when we're
    /// home while never blocking on a hung LAN address when we're away.
    static func resolve(
        plans: [Plan],
        serverName: String,
        session: URLSession,
        grace: Duration = connectionPreferenceGrace
    ) async -> ConnectionResolution {
        guard !plans.isEmpty else {
            return .failed("Could not connect to \(serverName)")
        }

        let planByIndex = Dictionary(uniqueKeysWithValues: plans.map { ($0.index, $0) })

        return await withTaskGroup(of: Event.self) { group -> ConnectionResolution in
            for plan in plans {
                group.addTask {
                    .probe(index: plan.index, result: await runProbe(session: session, plan: plan))
                }
            }

            var pending = Set(plans.map(\.index))
            var bestIndex: Int?
            var sawUnauthorized = false
            var lastFailure = "Could not connect to \(serverName)"
            var graceStarted = false

            func winner() -> ConnectionResolution? {
                guard let bestIndex, let plan = planByIndex[bestIndex] else { return nil }
                return .connected(plan.baseURL, plan.connection)
            }

            // Once a success exists, we can commit as soon as no still-pending
            // candidate outranks it (nothing better can arrive).
            func bestIsUnbeatable() -> Bool {
                guard let bestIndex else { return false }
                return !pending.contains { $0 < bestIndex }
            }

            for await event in group {
                switch event {
                case let .probe(index, result):
                    pending.remove(index)
                    switch result {
                    case .success:
                        if bestIndex == nil || index < bestIndex! {
                            bestIndex = index
                        }
                        if !graceStarted {
                            graceStarted = true
                            group.addTask {
                                try? await Task.sleep(for: grace)
                                return .graceElapsed
                            }
                        }
                    case let .failure(unauthorized, reason):
                        if unauthorized { sawUnauthorized = true }
                        lastFailure = reason
                    }

                    if bestIsUnbeatable(), let resolution = winner() {
                        group.cancelAll()
                        return resolution
                    }
                case .graceElapsed:
                    // A better candidate was still pending, but we've waited long
                    // enough — go with the best working connection we have.
                    if let resolution = winner() {
                        group.cancelAll()
                        return resolution
                    }
                }

                if pending.isEmpty {
                    break
                }
            }

            if let resolution = winner() {
                group.cancelAll()
                return resolution
            }
            if sawUnauthorized {
                return .unauthorized
            }
            return .failed(lastFailure)
        }
    }

    /// Runs one candidate's reachability probe (`/identity`) followed by an
    /// authorization check (`/library/sections`). Pure networking on Sendable
    /// inputs so it is safe to fan out across a task group off the main actor.
    private static func runProbe(session: URLSession, plan: Plan) async -> ChildResult {
        do {
            let (_, response) = try await session.data(for: plan.probeRequest)
            guard let http = response as? HTTPURLResponse else {
                return .failure(unauthorized: false, reason: "Invalid response")
            }
            if http.statusCode == 401 {
                return .failure(unauthorized: true, reason: "HTTP 401")
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure(unauthorized: false, reason: "HTTP \(http.statusCode)")
            }

            let (_, validationResponse) = try await session.data(for: plan.validationRequest)
            guard let validationHTTP = validationResponse as? HTTPURLResponse else {
                return .failure(unauthorized: false, reason: "Invalid validation response")
            }
            switch validationHTTP.statusCode {
            case 200...299:
                return .success
            case 401:
                return .failure(unauthorized: true, reason: "HTTP 401")
            default:
                return .failure(unauthorized: false, reason: "HTTP \(validationHTTP.statusCode)")
            }
        } catch is CancellationError {
            return .failure(unauthorized: false, reason: "Cancelled")
        } catch {
            return .failure(unauthorized: false, reason: error.localizedDescription)
        }
    }

    private static func validationURL(for baseURL: URL) -> URL? {
        let base = baseURL.absoluteString
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URLComponents(string: trimmed + "/library/sections")?.url
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private enum ChildResult: Sendable {
        case success
        case failure(unauthorized: Bool, reason: String)
    }

    private enum Event: Sendable {
        case probe(index: Int, result: ChildResult)
        case graceElapsed
    }
}
