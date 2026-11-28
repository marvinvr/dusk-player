import Foundation

extension MediaService {
    /// Live TV comes from one server only (v1). A DVR lineup is
    /// server-specific, tuners are a scarce per-server resource, and merging
    /// two guides has no sane UI yet — so everything here runs against the
    /// server discovery found the DVR on (`LiveTVProvider.serverID`), and
    /// only falls back to the highest-priority connected one.
    var liveTVServerID: String? {
        pool.primary?.serverID
    }

    /// The Live TV provider of the highest-priority connected server that has
    /// one. The DVR is often not on the primary server (or the primary is not
    /// the first to connect), so every connected server is asked.
    ///
    /// A server that could not answer is not a server without a DVR: unless
    /// another server has one, the pass is `.inconclusive` and the caller has
    /// to ask again. Treating a single slow or failed `/media/providers` as
    /// "no Live TV" hid the tab for the whole session (1.7.2).
    func discoverLiveTVProvider() async -> LiveTVDiscovery {
        let serverIDs = pool.connections.map(\.serverID)
        guard !serverIDs.isEmpty else { return .inconclusive(MediaServiceError.noServerConnected) }

        return await withTaskGroup(of: LiveTVDiscoveryEvent.self) { group in
            for serverID in serverIDs {
                group.addTask {
                    let outcome = await Result.capturing {
                        try await self.getLiveTVProvider(serverID: serverID)
                    }
                    return .answer(serverID, outcome)
                }
            }

            // Decide as soon as the answer can't change: every server answered,
            // or a DVR turned up and every higher-priority server has answered
            // (or had a short grace to). An unreachable server would otherwise
            // hold the tab back for its whole timeout.
            var results: [String: Result<LiveTVProvider?, Error>] = [:]
            var decision: LiveTVDiscovery?
            var graceStarted = false
            for await event in group {
                // Like `ServerProbe`: freeze the decision, then drain every
                // cancelled child instead of leaving the group early.
                guard decision == nil else { continue }

                switch event {
                case let .answer(serverID, result):
                    results[serverID] = result
                case .graceElapsed:
                    decision = LiveTVDiscovery(serverIDs: serverIDs, results: results)
                }

                if decision == nil {
                    let partial = LiveTVDiscovery(serverIDs: serverIDs, results: results)
                    if results.count == serverIDs.count {
                        decision = partial
                    } else if case .found(let provider) = partial {
                        let higherPriority = serverIDs.prefix { $0 != provider.serverID }
                        if higherPriority.allSatisfy({ results[$0] != nil }) {
                            decision = partial
                        } else if !graceStarted {
                            graceStarted = true
                            group.addTask {
                                try? await Task.sleep(for: Self.liveTVDiscoveryGrace)
                                return .graceElapsed
                            }
                        }
                    }
                }

                if decision != nil {
                    group.cancelAll()
                }
            }
            return decision ?? LiveTVDiscovery(serverIDs: serverIDs, results: results)
        }
    }

    func getLiveTVProvider(serverID: String? = nil) async throws -> LiveTVProvider? {
        try await liveTVFacet(serverID: serverID ?? liveTVServerID).source()
    }

    func getLiveTVChannels(
        provider: LiveTVProvider,
        serverID: String? = nil
    ) async throws -> [LiveChannel] {
        try await liveTVFacet(for: provider, serverID: serverID).channels(of: provider)
    }

    /// The DVR's tuner devices and the channels mapped to each, so the guide
    /// can show one section per device.
    func getLiveTVDevices(
        provider: LiveTVProvider,
        serverID: String? = nil
    ) async throws -> [LiveTVDevice] {
        try await liveTVFacet(for: provider, serverID: serverID).devices(of: provider)
    }

    func getLiveTVNowPlaying(
        provider: LiveTVProvider,
        channels: [LiveChannel],
        serverID: String? = nil
    ) async throws -> LiveTVLineup {
        try await liveTVFacet(for: provider, serverID: serverID).onNow(source: provider, channels: channels)
    }

    func getLiveTVGuide(
        provider: LiveTVProvider,
        channels: [LiveChannel],
        date: Date,
        serverID: String? = nil
    ) async throws -> LiveTVLineup {
        try await getLiveTVGuide(provider: provider, channels: channels, dates: [date], serverID: serverID)
    }

    /// The guide for every channel over each of `dates` (local calendar
    /// days), asked channel by channel (`LiveTVProviding.guide`).
    func getLiveTVGuide(
        provider: LiveTVProvider,
        channels: [LiveChannel],
        dates: [Date],
        serverID: String? = nil
    ) async throws -> LiveTVLineup {
        try await liveTVFacet(for: provider, serverID: serverID).guide(source: provider, channels: channels, days: dates)
    }

    /// Every channel's airings that overlap `window`, in one request
    /// (`LiveTVProviding.airings`).
    func getLiveTVGuideAirings(
        provider: LiveTVProvider,
        window: LiveTVGuideWindow,
        serverID: String? = nil
    ) async throws -> [LiveProgram] {
        try await liveTVFacet(for: provider, serverID: serverID).airings(source: provider, window: window)
    }

    /// Files `programs` under `channels` the way `provider`'s server does.
    /// Every channel gets a guide, empty when nothing matched (also for a
    /// source no server serves).
    func liveTVLineup(
        provider: LiveTVProvider,
        channels: [LiveChannel],
        programs: [LiveProgram]
    ) -> LiveTVLineup {
        guard let liveTV = liveTV(for: provider) else {
            return LiveTVLineup(
                provider: provider,
                guides: channels.map { LiveChannelGuide(channel: $0, programs: []) }
            )
        }
        return liveTV.lineup(source: provider, channels: channels, programs: programs)
    }

    /// A library copy of a past guide airing (in practice the DVR's recording
    /// of it) on the DVR's server, or nil when there is none
    /// (`LiveTVProviding.recording`).
    func liveTVRecording(for program: LiveProgram, provider: LiveTVProvider) async throws -> MediaItem? {
        try await liveTVFacet(for: provider).recording(for: program, source: provider)
    }

    /// Tunes `channel` and picks the stream (`LiveTVProviding.tune`).
    func tuneLiveTV(
        provider: LiveTVProvider,
        channel: LiveChannel,
        serverID: String? = nil,
        allowsDirectPlay: Bool = true
    ) async throws -> LiveTuneResult {
        try await liveTVFacet(for: provider, serverID: serverID)
            .tune(channel, source: provider, allowsDirectPlay: allowsDirectPlay)
    }

    private static let liveTVDiscoveryGrace: Duration = .seconds(2)
}

// MARK: - Routing

extension MediaService {
    /// The Live TV facet of the server `source` lives on (`serverID` first,
    /// then the source's own, then `liveTVServerID`), or nil when that is not
    /// a server the pool knows: an IPTV source is never routed to a server.
    ///
    func liveTV(for source: LiveTVProvider, serverID: String? = nil) -> (any LiveTVProviding)? {
        let targetID = serverID ?? source.serverID ?? liveTVServerID
        if let targetID = targetID?.nilIfEmpty, !pool.knownServerIDs.contains(targetID) {
            return nil
        }
        return serverProvider(for: targetID).liveTV
    }

    /// `liveTV(for:)`, throwing for a source no server serves.
    private func liveTVFacet(for source: LiveTVProvider, serverID: String? = nil) throws -> any LiveTVProviding {
        guard let liveTV = liveTV(for: source, serverID: serverID) else {
            throw MediaServiceError.noServerConnected
        }
        return liveTV
    }

    /// The facet of `serverID` (nil: the highest-priority server), for
    /// discovery, before there is a source.
    private func liveTVFacet(serverID: String?) throws -> any LiveTVProviding {
        guard let liveTV = serverProvider(for: serverID).liveTV else {
            throw MediaServiceError.noServerConnected
        }
        return liveTV
    }
}

private enum LiveTVDiscoveryEvent: Sendable {
    case answer(String, Result<LiveTVProvider?, Error>)
    case graceElapsed
}

/// The outcome of one Live TV discovery pass over the connected servers.
enum LiveTVDiscovery {
    /// The highest-priority server with a DVR answered.
    case found(LiveTVProvider)
    /// Every connected server answered, and none has a DVR.
    case none
    /// No DVR found, but at least one server could not answer. Ask again.
    case inconclusive(Error)

    /// `serverIDs` in priority order. A found DVR wins over servers that failed,
    /// even higher-priority ones: a DVR in hand is better than a guess.
    init(serverIDs: [String], results: [String: Result<LiveTVProvider?, Error>]) {
        var failure: Error?
        for serverID in serverIDs {
            switch results[serverID] {
            case .success(let provider?):
                self = .found(provider)
                return
            case .success(nil):
                break
            case .failure(let error) where !Self.meansNoLiveTV(error):
                failure = failure ?? error
            case .failure:
                break
            case nil:
                failure = failure ?? MediaServiceError.noServerConnected
            }
        }
        self = failure.map { .inconclusive($0) } ?? .none
    }

    /// Answers that will not change by asking again: the server refuses this
    /// user its providers (a managed or shared user), or sends a list Dusk
    /// cannot read. Everything else (timeouts, 5xx, a dropped connection,
    /// cancellation) says nothing about the DVR.
    private static func meansNoLiveTV(_ error: Error) -> Bool {
        switch error as? MediaServiceError {
        case .unauthorized, .decodingError:
            true
        case .httpError(let statusCode):
            [401, 403, 404].contains(statusCode)
        default:
            false
        }
    }
}
