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
    /// the first to connect), so every connected server is asked. Throws only
    /// when no server answered at all, so the caller retries later.
    func discoverLiveTVProvider() async throws -> PlexLiveTVProvider? {
        let serverIDs = pool.connections.map(\.serverID)
        guard !serverIDs.isEmpty else { throw PlexServiceError.noServerConnected }

        let results = await withTaskGroup(of: (String, Result<PlexLiveTVProvider?, Error>).self) { group in
            for serverID in serverIDs {
                group.addTask {
                    do {
                        return (serverID, .success(try await self.getLiveTVProvider(serverID: serverID)))
                    } catch {
                        return (serverID, .failure(error))
                    }
                }
            }
            var results: [String: Result<PlexLiveTVProvider?, Error>] = [:]
            for await (serverID, result) in group {
                results[serverID] = result
            }
            return results
        }

        var firstError: Error?
        var anyServerAnswered = false
        for serverID in serverIDs {
            switch results[serverID] {
            case .success(let provider?):
                return provider
            case .success(nil):
                anyServerAnswered = true
            case .failure(let error):
                firstError = firstError ?? error
            case nil:
                break
            }
        }
        if let firstError, !anyServerAnswered {
            throw firstError
        }
        return nil
    }

    func getLiveTVProvider(serverID: String? = nil) async throws -> PlexLiveTVProvider? {
        let targetID = try resolveServerID(serverID ?? liveTVServerID)
        let data = try await rawServerRequest(path: "/media/providers", serverID: targetID)
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

    private static let liveTVDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
