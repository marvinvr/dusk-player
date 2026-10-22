import Foundation

extension PlexService {
    /// Live TV comes from one server only (v1). A DVR lineup is
    /// server-specific, tuners are a scarce per-server resource, and merging
    /// two guides has no sane UI yet — so everything here runs against the
    /// server discovery found the DVR on (`PlexLiveTVProvider.serverID`), and
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
        guard !serverIDs.isEmpty else { return .inconclusive(PlexServiceError.noServerConnected) }

        return await withTaskGroup(of: LiveTVDiscoveryEvent.self) { group in
            for serverID in serverIDs {
                group.addTask {
                    do {
                        return .answer(serverID, .success(try await self.getLiveTVProvider(serverID: serverID)))
                    } catch {
                        return .answer(serverID, .failure(error))
                    }
                }
            }

            // Decide as soon as the answer can't change: every server answered,
            // or a DVR turned up and every higher-priority server has answered
            // (or had a short grace to). An unreachable server would otherwise
            // hold the tab back for its whole timeout.
            var results: [String: Result<PlexLiveTVProvider?, Error>] = [:]
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

    func getLiveTVProvider(serverID: String? = nil) async throws -> PlexLiveTVProvider? {
        let targetID = try resolveServerID(serverID ?? liveTVServerID)
        // A timeout above `requestResourceTimeout` sends this through
        // `slowQuerySession`, i.e. its own connections to the server: on a big
        // library Home's slow reads can fill the shared session's, and a cheap
        // `/media/providers` queued behind them used up its 30s (1.7.2). That
        // session's 120s budget is what ends a hung answer (measured; the 45s
        // itself does not cut it off); `LiveTVViewModel.discover()` then asks
        // again.
        let data = try await rawServerRequest(
            path: "/media/providers",
            timeoutInterval: Self.liveTVDiscoveryTimeout,
            serverID: targetID
        )
        let response = try decodeJSON(PlexMediaProvidersResponse.self, from: data, serverID: targetID)
        return response.MediaContainer.MediaProvider?
            .compactMap(\.liveTVProvider)
            .first?
            .on(serverID: targetID)
    }

    func getLiveTVChannels(
        provider: PlexLiveTVProvider,
        serverID: String? = nil
    ) async throws -> [PlexLiveChannel] {
        let targetID = try resolveServerID(serverID ?? provider.serverID ?? liveTVServerID)
        let data = try await rawServerRequest(path: provider.channelsKey, serverID: targetID)
        let response = try decodeJSON(PlexLiveChannelsResponse.self, from: data, serverID: targetID)
        return (response.MediaContainer.Channel ?? []).sorted {
            Self.channelSortKey($0).lexicographicallyPrecedes(Self.channelSortKey($1))
        }
    }

    func getLiveTVNowPlaying(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel],
        serverID: String? = nil
    ) async throws -> PlexLiveTVLineup {
        let programs: [PlexLiveProgram] = try await fetchMetadata(
            path: provider.watchNowKey,
            serverID: serverID ?? provider.serverID ?? liveTVServerID
        )
        return PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)
    }

    func getLiveTVGuide(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel],
        date: Date,
        serverID: String? = nil
    ) async throws -> PlexLiveTVLineup {
        let dateValue = Self.liveTVDateFormatter.string(from: date)
        let targetID = serverID ?? provider.serverID ?? liveTVServerID

        // One request per channel: the grid answers only for the LAST of
        // repeated `channelGridKey` values (XMLTV and cloud guides alike), so
        // batching left every channel but one per batch empty (issue #17).
        // A few run at a time so long lineups stay quick.
        let results = await withTaskGroup(of: Result<[PlexLiveProgram], Error>.self) { group in
            var pending = channels.makeIterator()
            for _ in 0..<Self.liveTVGuideConcurrency {
                guard let channel = pending.next() else { break }
                group.addTask {
                    await self.liveTVGridPrograms(provider: provider, channel: channel, date: dateValue, serverID: targetID)
                }
            }
            var results: [Result<[PlexLiveProgram], Error>] = []
            for await result in group {
                results.append(result)
                if let channel = pending.next() {
                    group.addTask {
                        await self.liveTVGridPrograms(provider: provider, channel: channel, date: dateValue, serverID: targetID)
                    }
                }
            }
            return results
        }

        // A channel whose guide failed keeps an empty (still tunable) row;
        // only a guide that failed for every channel is an error.
        var programs: [PlexLiveProgram] = []
        var firstError: Error?
        for result in results {
            switch result {
            case .success(let channelPrograms):
                programs.append(contentsOf: channelPrograms)
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        if let firstError, !results.contains(where: { if case .success = $0 { true } else { false } }) {
            throw firstError
        }

        return PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)
    }

    private func liveTVGridPrograms(
        provider: PlexLiveTVProvider,
        channel: PlexLiveChannel,
        date: String,
        serverID: String?
    ) async -> Result<[PlexLiveProgram], Error> {
        do {
            let programs: [PlexLiveProgram] = try await fetchMetadata(
                path: provider.gridKey,
                queryItems: [
                    URLQueryItem(name: "channelGridKey", value: channel.gridKey),
                    URLQueryItem(name: "date", value: date),
                ],
                serverID: serverID
            )
            return .success(programs)
        } catch {
            return .failure(error)
        }
    }

    func tuneLiveTV(
        provider: PlexLiveTVProvider,
        channel: PlexLiveChannel,
        serverID: String? = nil
    ) async throws -> PlexLiveTuneResult {
        let targetID = try resolveServerID(serverID ?? provider.serverID ?? liveTVServerID)
        let path = "/livetv/dvrs/\(provider.dvrID)/channels/\(channel.tuneIdentifier)/tune"
        let playbackSessionIdentifier = UUID().uuidString
        let data = try await rawServerRequest(
            method: "POST",
            path: path,
            queryItems: [
                URLQueryItem(
                    name: "X-Plex-Session-Identifier",
                    value: playbackSessionIdentifier
                ),
            ],
            serverID: targetID
        )
        let response = try decodeJSON(PlexLiveTuneResponse.self, from: data, serverID: targetID)
        guard let tuned = response.MediaContainer.tunedSession,
              let sessionID = tuned.sessionID else {
            let message = response.MediaContainer.message?.nilIfEmpty
                ?? "Plex did not return a Live TV session."
            throw PlexServiceError.decodingError(message)
        }

        let sessionPath = tuned.sessionPath
        let media = tuned.media?.makeMedia(sessionPath: sessionPath)
            ?? makeFallbackLiveTVMedia(sessionPath: sessionPath)
        guard let part = media.firstAvailablePart else {
            throw PlexServiceError.decodingError("Plex did not return a playable Live TV stream.")
        }

        let requestedTranscodeSessionID = UUID().uuidString
        let liveStream = try await liveTVStreamURL(
            sessionPath: sessionPath,
            sessionIdentifier: playbackSessionIdentifier,
            transcodeSessionID: requestedTranscodeSessionID,
            serverID: targetID
        )

        let playbackURL: URL
        let transcodeSessionID: String?
        switch liveStream.outcome {
        case .transcodeAvailable:
            playbackURL = liveStream.url
            transcodeSessionID = requestedTranscodeSessionID
        case .directPlayOnly:
            let streamPath = tuned.playbackPath
                ?? "\(sessionPath)/\(clientIdentifier)/index.m3u8"
            guard let connection = pool.connection(for: targetID),
                  let directURL = buildURL(
                    base: connection.baseURL.absoluteString,
                    path: streamPath,
                    queryItems: [URLQueryItem(name: "X-Plex-Token", value: connection.token)]
                  ) else {
                throw PlexServiceError.invalidURL
            }
            playbackURL = directURL
            transcodeSessionID = nil
        case .failed(let message):
            throw PlexServiceError.decodingError(
                message?.nilIfEmpty ?? "Plex could not create a Live TV stream."
            )
        }

        return PlexLiveTuneResult(
            serverID: targetID,
            sessionID: sessionID,
            playbackSessionIdentifier: playbackSessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            playbackURL: playbackURL,
            media: media,
            part: part
        )
    }

    private func makeFallbackLiveTVMedia(sessionPath: String) -> PlexMedia {
        let part = PlexMediaPart(
            id: 0,
            key: sessionPath,
            file: nil,
            size: nil,
            container: "mpegts",
            duration: nil,
            videoProfile: nil,
            audioProfile: nil,
            accessible: true,
            exists: true,
            streams: []
        )
        return PlexMedia(
            id: 0,
            container: "hls",
            videoCodec: nil,
            audioCodec: nil,
            videoResolution: nil,
            videoProfile: nil,
            audioProfile: nil,
            audioChannels: nil,
            width: nil,
            height: nil,
            bitrate: nil,
            duration: nil,
            optimizedForStreaming: nil,
            parts: [part]
        )
    }

    private static func channelSortKey(_ channel: PlexLiveChannel) -> [Int] {
        let components = (channel.vcn ?? channel.id)
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        return components.isEmpty ? [Int.max] : components
    }

    private static let liveTVGuideConcurrency = 6
    static let liveTVDiscoveryTimeout: TimeInterval = 45
    private static let liveTVDiscoveryGrace: Duration = .seconds(2)

    private static let liveTVDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum LiveTVDiscoveryEvent: Sendable {
    case answer(String, Result<PlexLiveTVProvider?, Error>)
    case graceElapsed
}

/// The outcome of one Live TV discovery pass over the connected servers.
enum LiveTVDiscovery {
    /// The highest-priority server with a DVR answered.
    case found(PlexLiveTVProvider)
    /// Every connected server answered, and none has a DVR.
    case none
    /// No DVR found, but at least one server could not answer. Ask again.
    case inconclusive(Error)

    /// `serverIDs` in priority order. A found DVR wins over servers that failed,
    /// even higher-priority ones: a DVR in hand is better than a guess.
    init(serverIDs: [String], results: [String: Result<PlexLiveTVProvider?, Error>]) {
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
                failure = failure ?? PlexServiceError.noServerConnected
            }
        }
        self = failure.map { .inconclusive($0) } ?? .none
    }

    /// Answers that will not change by asking again: the server refuses this
    /// user its providers (a managed or shared user), or sends a list Dusk
    /// cannot read. Everything else (timeouts, 5xx, a dropped connection,
    /// cancellation) says nothing about the DVR.
    private static func meansNoLiveTV(_ error: Error) -> Bool {
        switch error as? PlexServiceError {
        case .unauthorized, .decodingError:
            true
        case .httpError(let statusCode):
            [401, 403, 404].contains(statusCode)
        default:
            false
        }
    }
}
