import Foundation

@MainActor
@Observable
final class LiveTVViewModel {
    private let plexService: PlexService

    private(set) var provider: PlexLiveTVProvider?
    private(set) var channels: [PlexLiveChannel] = []
    private(set) var lineup: PlexLiveTVLineup?
    private(set) var nowPlayingLineup: PlexLiveTVLineup?
    private(set) var selectedDate = Calendar.current.startOfDay(for: .now)
    private(set) var isLoading = false
    private(set) var isLoadingNowPlaying = false
    private(set) var error: String?

    private var loadedDate: Date?
    /// The Plex Home profile the provider was found for.
    private var discoveredProfileID: String?

    /// Whether a connected server has a DVR. Drives the tab and the Home shelf.
    var isAvailable: Bool { provider != nil }

    private let discoveryRetryDelay: Duration

    init(plexService: PlexService, discoveryRetryDelay: Duration = .seconds(2)) {
        self.plexService = plexService
        self.discoveryRetryDelay = discoveryRetryDelay
    }

    /// Runs whenever the set of connected servers changes, on its own task so
    /// slow library loads never hold it up. Keeps asking, backing off, until
    /// either a server has a DVR or every connected server has said it has
    /// none: one slow or failed `/media/providers` is not "no Live TV", and
    /// latching it hid the tab for the whole session (1.7.2).
    func discover() async {
        resetIfProfileChanged()
        guard provider == nil else { return }

        var delay = discoveryRetryDelay
        while !Task.isCancelled {
            switch await discoverOnce() {
            case .found, .none:
                return
            case .inconclusive:
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, Self.discoveryMaxRetryDelay)
            }
        }
    }

    /// One discovery pass. Only a found DVR changes anything, and it is kept
    /// for the session: a later pass that fails (or overlaps this one), or a
    /// server that briefly drops out while it reconnects, must not take the
    /// tab away under the user.
    private func discoverOnce() async -> LiveTVDiscovery {
        let profileID = plexService.serverContentRevision.profileID
        let result = await plexService.discoverLiveTVProvider()
        if case .found(let found) = result,
           provider == nil,
           profileID == plexService.serverContentRevision.profileID {
            provider = found
            discoveredProfileID = profileID
        }
        return result
    }

    /// A different Plex Home member sees different servers and DVRs.
    private func resetIfProfileChanged() {
        guard provider != nil,
              discoveredProfileID != plexService.serverContentRevision.profileID else { return }
        provider = nil
        channels = []
        lineup = nil
        nowPlayingLineup = nil
        loadedDate = nil
    }

    /// The provider, discovering it first when no pass has found one yet.
    private func resolveProvider() async throws -> PlexLiveTVProvider? {
        resetIfProfileChanged()
        if let provider { return provider }
        if case .inconclusive(let error) = await discoverOnce(), provider == nil {
            throw error
        }
        return provider
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, lineup != nil, Calendar.current.isDate(loadedDate ?? .distantPast, inSameDayAs: selectedDate) {
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            guard let provider = try await resolveProvider() else {
                lineup = nil
                return
            }

            if channels.isEmpty || force {
                channels = try await plexService.getLiveTVChannels(provider: provider)
            }
            lineup = try await plexService.getLiveTVGuide(
                provider: provider,
                channels: channels,
                date: selectedDate
            )
            loadedDate = selectedDate
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Feeds the Home shelf. Separate from `load()`'s flag: a guide load in
    /// flight used to swallow this call, and the shelf never asked again.
    func loadNowPlaying(force: Bool = false) async {
        guard !isLoadingNowPlaying else { return }
        guard force || nowPlayingLineup == nil else { return }
        isLoadingNowPlaying = true
        defer { isLoadingNowPlaying = false }

        do {
            guard let provider = try await resolveProvider() else { return }
            if channels.isEmpty {
                channels = try await plexService.getLiveTVChannels(provider: provider)
            }
            nowPlayingLineup = try await plexService.getLiveTVNowPlaying(
                provider: provider,
                channels: channels
            )
        } catch {
            // The shelf just stays hidden; the Live TV tab shows the details.
        }
    }

    func selectDate(_ date: Date) async {
        selectedDate = Calendar.current.startOfDay(for: date)
        await load(force: true)
    }

    func imageURL(for path: String?, width: Int, height: Int) -> URL? {
        // Explicit because `imageURL` falls back to the primary server, while
        // the DVR may live on another one.
        plexService.imageURL(
            for: path,
            serverID: provider?.serverID ?? plexService.liveTVServerID,
            width: width,
            height: height
        )
    }

    var dateOptions: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (-1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private static let discoveryMaxRetryDelay: Duration = .seconds(60)
}
