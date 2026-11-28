import Foundation

/// Jellyfin's sign-in (docs/jellyfin/04-architecture.md §7.2): a server
/// address, then a Quick Connect code approved on another device or a user
/// name and password. The steps are `SignInJellyfinFlowView`; the result goes
/// to `MediaService.completeJellyfinSignIn`.
///
/// One attempt holds one fresh `DeviceId` from the moment it starts: the token
/// it ends with is bound to that id, and no other account shares it.
struct JellyfinSignInFlow: SignInFlow {
    let account: JellyfinAccountProvider

    var kind: ProviderKind { .jellyfin }
    var productName: String { "Jellyfin" }

    /// A server that answered as Jellyfin at one of the typed address's URLs.
    struct Server: Sendable, Hashable {
        let baseURL: URL
        let info: JellyfinPublicSystemInfoDTO
        let quickConnectEnabled: Bool
        /// The `DeviceId` this attempt signs in with.
        let deviceID: String

        var name: String { info.serverName?.nilIfEmpty ?? baseURL.host ?? "Jellyfin" }
    }

    /// The end of a sign-in: everything the account needs to save.
    struct Result: Sendable {
        let record: JellyfinAccountRecord
        let accessToken: String
    }

    enum Failure: Error, Equatable, LocalizedError {
        case invalidAddress
        case unreachable(String)
        case notJellyfin
        case wrongCredentials
        case wrongPassword
        case userUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "Enter a server address, like jellyfin.example.com."
            case let .unreachable(reason): reason
            case .notJellyfin: "No Jellyfin server answered at this address."
            case .wrongCredentials: "Incorrect user name or password."
            case .wrongPassword: "Incorrect password."
            case .userUnavailable: "That user is no longer available."
            }
        }
    }

    // MARK: - Address

    /// Tries every URL the address stands for at once and takes the most
    /// preferred one that answers as a Jellyfin server.
    @MainActor
    func connect(to address: String) async throws -> Server {
        let candidates = JellyfinAddress.candidates(for: address)
        guard !candidates.isEmpty else { throw Failure.invalidAddress }
        let deviceID = JellyfinClientIdentity.newDeviceID()
        let identity = JellyfinClientIdentity.dusk(deviceID: deviceID)
        let transport = account.sessions.probeTransport

        let outcomes = await withTaskGroup(of: (Int, ProbeOutcome).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    (index, await Self.probePublicInfo(baseURL: url, identity: identity, transport: transport))
                }
            }
            var outcomes = [ProbeOutcome?](repeating: nil, count: candidates.count)
            for await (index, outcome) in group {
                outcomes[index] = outcome
                // The most preferred URL that answered, once every URL before it failed.
                if let first = outcomes.firstIndex(where: { $0 == nil || $0?.info != nil }),
                   outcomes[first]?.info != nil {
                    group.cancelAll()
                    break
                }
            }
            return outcomes
        }

        guard let index = outcomes.firstIndex(where: { $0?.info != nil }),
              let info = outcomes[index]?.info else {
            if outcomes.contains(where: { $0?.isOtherServer == true }) { throw Failure.notJellyfin }
            let reason = outcomes.lazy.compactMap { $0?.failure }.first
            throw Failure.unreachable(reason ?? "Could not reach this server.")
        }
        let baseURL = candidates[index]
        let client = JellyfinClient(baseURL: baseURL, identity: identity, transport: transport)
        let quickConnect = (try? await client.send(JellyfinAPI.quickConnectEnabled())) ?? false
        return Server(baseURL: baseURL, info: info, quickConnectEnabled: quickConnect, deviceID: deviceID)
    }

    private struct ProbeOutcome: Sendable, Equatable {
        var info: JellyfinPublicSystemInfoDTO?
        var isOtherServer = false
        var failure: String?
    }

    private static func probePublicInfo(
        baseURL: URL,
        identity: JellyfinClientIdentity,
        transport: any JellyfinTransport
    ) async -> ProbeOutcome {
        let client = JellyfinClient(baseURL: baseURL, identity: identity, transport: transport)
        do {
            let info = try await client.send(JellyfinAPI.publicSystemInfo())
            // Emby answers the same route; only Jellyfin names itself so.
            if let product = info.productName, !product.localizedCaseInsensitiveContains("jellyfin") {
                return ProbeOutcome(isOtherServer: true)
            }
            return ProbeOutcome(info: info)
        } catch let error as JellyfinError {
            switch error {
            case .transport(_, let description): return ProbeOutcome(failure: description)
            case .decoding, .unexpectedResponse, .notFound: return ProbeOutcome(isOtherServer: true)
            default: return ProbeOutcome(failure: error.localizedDescription)
            }
        } catch {
            return ProbeOutcome(failure: error.localizedDescription)
        }
    }

    // MARK: - Password

    @MainActor
    func signIn(to server: Server, username: String, password: String) async throws -> Result {
        let client = makeClient(for: server)
        do {
            let result = try await client.send(JellyfinAPI.authenticateByName(username: username, password: password))
            return try await finish(result, server: server, client: client)
        } catch JellyfinError.unauthorized {
            throw Failure.wrongCredentials
        }
    }

    // MARK: - Quick Connect

    /// Starts a Quick Connect request; its `code` is what the user enters on
    /// another device.
    @MainActor
    func startQuickConnect(on server: Server) async throws -> JellyfinQuickConnectResultDTO {
        try await makeClient(for: server).send(JellyfinAPI.quickConnectInitiate())
    }

    /// Polls `secret` until it is approved, then signs in with it. Returns nil
    /// when the request expired (the server forgot the secret).
    @MainActor
    func waitForQuickConnect(secret: String, on server: Server) async throws -> Result? {
        let client = makeClient(for: server)
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(2))
            let state: JellyfinQuickConnectResultDTO
            do {
                state = try await client.send(JellyfinAPI.quickConnectState(secret: secret))
            } catch JellyfinError.notFound {
                return nil
            } catch let error as JellyfinError {
                if case .transport = error { continue }
                throw error
            }
            guard state.authenticated else { continue }
            let result = try await client.send(JellyfinAPI.authenticateWithQuickConnect(secret: secret))
            return try await finish(result, server: server, client: client)
        }
        throw CancellationError()
    }

    // MARK: - Shared

    @MainActor
    private func makeClient(for server: Server) -> JellyfinClient {
        JellyfinClient(
            baseURL: server.baseURL,
            identity: .dusk(deviceID: server.deviceID),
            transport: account.sessions.probeTransport
        )
    }

    /// Builds the record and tells the server what this client can do
    /// (`POST /Sessions/Capabilities/Full`, once per sign-in).
    @MainActor
    private func finish(
        _ result: JellyfinAuthenticationResultDTO,
        server: Server,
        client: JellyfinClient
    ) async throws -> Result {
        let serverID = JellyfinID.normalized(result.serverID?.nilIfEmpty ?? server.info.id)
        let userID = JellyfinID.normalized(result.user.id)
        let record = JellyfinAccountRecord(
            serverID: serverID,
            serverName: server.name,
            serverVersion: server.info.version,
            userID: userID,
            userName: result.user.name?.nilIfEmpty ?? "Jellyfin",
            baseURL: server.baseURL,
            localAddress: JellyfinAddress.localAddress(server.info.localAddress, distinctFrom: server.baseURL),
            deviceID: server.deviceID,
            policy: JellyfinPolicySnapshot(result.user.policy),
            hasPrimaryImage: result.user.primaryImageTag?.nilIfEmpty != nil
        )
        let signedIn = client.signedIn(JellyfinCredentials(accessToken: result.accessToken, userID: userID))
        _ = try? await signedIn.send(JellyfinAPI.postCapabilities())
        return Result(record: record, accessToken: result.accessToken)
    }

    /// The account a finished sign-in stands for.
    func storedAccount(for result: Result) -> StoredAccount {
        JellyfinAccountProvider.storedAccount(for: result.record)
    }
}
