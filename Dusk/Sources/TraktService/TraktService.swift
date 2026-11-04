import Foundation
import OSLog

private let traktLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "Trakt"
)

/// Trakt watch tracking: the device-code sign-in per Plex profile, and adding
/// finished movies/episodes to the account's history (`/sync/history`).
///
/// Rules (see `docs/trakt.md`):
/// - Nothing here may ever affect playback. `recordFinished` only queues and
///   kicks a background flush; every failure is logged and swallowed.
/// - One small persisted retry queue, flushed on record, launch and
///   foreground. No history import, no ratings or watchlist.
@MainActor
@Observable
final class TraktService {
    enum SignInState: Equatable {
        case idle
        case requestingCode
        case awaitingApproval(TraktDeviceCode)
        case failed(String)
    }

    let configuration: TraktConfiguration
    private(set) var signInState: SignInState = .idle
    private(set) var accounts: [String: TraktTokens]

    @ObservationIgnored private let plexService: PlexService
    @ObservationIgnored private let requests: TraktRequestBuilder
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let queue: TraktHistoryQueue
    @ObservationIgnored private var pending: [TraktHistoryEntry]
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var isFlushing = false

    init(
        plexService: PlexService,
        configuration: TraktConfiguration = .current,
        session: URLSession = .shared,
        queue: TraktHistoryQueue = TraktHistoryQueue()
    ) {
        self.plexService = plexService
        self.configuration = configuration
        self.session = session
        self.queue = queue
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        #if os(tvOS)
        let platform = "tvOS"
        #else
        let platform = "iOS"
        #endif
        requests = TraktRequestBuilder(configuration: configuration, userAgent: "Dusk/\(version) (\(platform))")
        accounts = configuration.isConfigured ? TraktCredentialStore.load() : [:]
        pending = configuration.isConfigured ? queue.load() : []
    }

    // MARK: - State

    /// False when the build carries no Trakt client ID/secret; the setting is hidden.
    var isAvailable: Bool { configuration.isConfigured }

    var activeAccount: TraktTokens? {
        plexService.activeProfileID.flatMap { accounts[$0] }
    }

    var isConnected: Bool { activeAccount != nil }

    var connectionSubtitle: String {
        guard let account = activeAccount else { return "Not connected" }
        if let username = account.username?.nilIfEmpty { return "Connected as \(username)" }
        return "Connected"
    }

    // MARK: - Sign in (device flow)

    func startSignIn() {
        guard isAvailable, let profileID = plexService.activeProfileID else { return }
        pollingTask?.cancel()
        signInState = .requestingCode
        pollingTask = Task { [weak self] in
            await self?.runDeviceFlow(profileID: profileID)
        }
    }

    /// Stops a running sign-in. A failure message stays up until the next attempt.
    func cancelSignIn() {
        pollingTask?.cancel()
        pollingTask = nil
        if case .failed = signInState { return }
        signInState = .idle
    }

    private func runDeviceFlow(profileID: String) async {
        let code: TraktDeviceCode
        do {
            let (data, status) = try await send(requests.deviceCode())
            guard status == 200 else {
                traktLogger.error("Device code request failed: HTTP \(status)")
                signInState = .failed("Couldn’t reach Trakt. Try again.")
                return
            }
            code = try JSONDecoder().decode(TraktDeviceCode.self, from: data)
        } catch {
            guard !Task.isCancelled else { return }
            traktLogger.error("Device code request failed: \(error.localizedDescription)")
            signInState = .failed("Couldn’t reach Trakt. Try again.")
            return
        }
        guard !Task.isCancelled else { return }
        signInState = .awaitingApproval(code)

        let deadline = Date.now.addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = max(code.interval, 1)
        while Date.now < deadline {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }

            let data: Data
            let status: Int
            do {
                (data, status) = try await send(requests.deviceToken(deviceCode: code.deviceCode))
            } catch {
                guard !Task.isCancelled else { return }
                continue // transient network error: keep polling until the code expires
            }
            guard !Task.isCancelled else { return }

            if status == 200, let response = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) {
                var tokens = response.tokens(username: nil)
                tokens.username = await fetchUsername(accessToken: tokens.accessToken)
                guard !Task.isCancelled else { return }
                accounts[profileID] = tokens
                TraktCredentialStore.save(accounts)
                signInState = .idle
                pollingTask = nil
                traktLogger.info("Trakt connected")
                return
            }

            switch TraktDevicePollResult(status: status) {
            case .pending:
                continue
            case .slowDown:
                interval += 1
            case .denied:
                signInState = .failed("Sign-in was denied on Trakt.")
                return
            case .expired, .invalid:
                signInState = .failed("The code expired. Get a new one.")
                return
            case .failed(let pollStatus):
                traktLogger.error("Device token poll failed: HTTP \(pollStatus)")
                continue
            }
        }
        signInState = .failed("The code expired. Get a new one.")
    }

    func disconnect() {
        guard let profileID = plexService.activeProfileID, let tokens = accounts.removeValue(forKey: profileID) else { return }
        TraktCredentialStore.save(accounts)
        pending.removeAll { $0.profileID == profileID }
        queue.save(pending)
        let request = requests.revoke(accessToken: tokens.accessToken)
        let session = session
        Task.detached {
            _ = try? await session.data(for: request)
        }
    }

    private func fetchUsername(accessToken: String) async -> String? {
        guard let (data, status) = try? await send(requests.userSettings(accessToken: accessToken)),
              status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = object["user"] as? [String: Any] else {
            return nil
        }
        return (user["username"] as? String)?.nilIfEmpty
    }

    // MARK: - History

    /// Called once per playback session when Plex scrobbles it (the 90 %
    /// mark or a finished stop). Never throws, never blocks.
    func recordFinished(type: PlexMediaType, guid: String?, guids: [PlexGuid], at date: Date = .now) {
        guard isAvailable,
              let profileID = plexService.activeProfileID,
              accounts[profileID] != nil else { return }
        guard let entry = TraktHistoryMapper.entry(
            type: type, guid: guid, guids: guids, watchedAt: date, profileID: profileID
        ) else {
            traktLogger.info("Finished \(type.rawValue, privacy: .public) has no Trakt-matchable id; skipped")
            return
        }
        pending.append(entry)
        queue.save(pending)
        Task { await flushPending() }
    }

    /// Sends queued entries, one request per profile. Safe to call any time.
    func flushPending() async {
        guard isAvailable, !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        // Entries of a disconnected profile can never be sent.
        pending.removeAll { accounts[$0.profileID] == nil }

        for profileID in Set(pending.map(\.profileID)) {
            let batch = pending.filter { $0.profileID == profileID }
            let outcome = await send(batch, profileID: profileID)
            let ids = Set(batch.map(\.id))
            switch outcome {
            case .done:
                pending.removeAll { ids.contains($0.id) }
            case .retryLater:
                for index in pending.indices where ids.contains(pending[index].id) {
                    pending[index].attempts += 1
                }
            }
        }
        pending.removeAll { $0.attempts >= TraktHistoryQueue.maximumAttempts }
        queue.save(pending)
    }

    private enum SendOutcome { case done, retryLater }

    private func send(_ batch: [TraktHistoryEntry], profileID: String) async -> SendOutcome {
        guard let token = await validAccessToken(profileID: profileID) else {
            return accounts[profileID] == nil ? .done : .retryLater
        }
        do {
            var (data, status) = try await send(requests.addToHistory(batch, accessToken: token))
            if status == 401, let refreshed = await refreshTokens(profileID: profileID) {
                (data, status) = try await send(requests.addToHistory(batch, accessToken: refreshed.accessToken))
            }
            switch status {
            case 200..<300:
                logNotFound(data)
                return .done
            case 401, 429, 500...:
                traktLogger.error("History add failed: HTTP \(status); will retry")
                return .retryLater
            default:
                // 400/403/404/409/422: the request itself is wrong; retrying won't help.
                traktLogger.error("History add rejected: HTTP \(status); dropped")
                return .done
            }
        } catch {
            traktLogger.error("History add failed: \(error.localizedDescription); will retry")
            return .retryLater
        }
    }

    private func logNotFound(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notFound = object["not_found"] as? [String: Any] else { return }
        let count = notFound.values.compactMap { ($0 as? [Any])?.count }.reduce(0, +)
        if count > 0 {
            traktLogger.info("Trakt matched no title for \(count) history item(s)")
        }
    }

    // MARK: - Tokens

    private func validAccessToken(profileID: String) async -> String? {
        guard let tokens = accounts[profileID] else { return nil }
        // Trakt access tokens are short-lived; refresh a little ahead of expiry.
        if tokens.expires(within: 60 * 60) {
            return await refreshTokens(profileID: profileID)?.accessToken
        }
        return tokens.accessToken
    }

    private func refreshTokens(profileID: String) async -> TraktTokens? {
        guard let current = accounts[profileID] else { return nil }
        do {
            let (data, status) = try await send(requests.refresh(refreshToken: current.refreshToken))
            if status == 200, let response = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) {
                let tokens = response.tokens(username: current.username)
                accounts[profileID] = tokens
                TraktCredentialStore.save(accounts)
                return tokens
            }
            if status == 400 || status == 401 {
                // Refresh token revoked or expired: the link is gone.
                traktLogger.error("Trakt refresh rejected (HTTP \(status)); account disconnected")
                accounts[profileID] = nil
                TraktCredentialStore.save(accounts)
            }
        } catch {
            traktLogger.error("Trakt refresh failed: \(error.localizedDescription)")
        }
        return nil
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
