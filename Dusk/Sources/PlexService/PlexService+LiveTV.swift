import Foundation

extension PlexService {
    /// Live TV comes from one server only (v1): the highest-priority connected
    /// one. A DVR lineup is server-specific, tuners are a scarce per-server
    /// resource, and merging two guides has no sane UI yet — so everything here
    /// defaults to this server rather than fanning out.
    var liveTVServerID: String? {
        pool.primary?.serverID
    }

    func getLiveTVProvider(serverID: String? = nil) async throws -> PlexLiveTVProvider? {
        let targetID = try resolveServerID(serverID ?? liveTVServerID)
        let data = try await rawServerRequest(path: "/media/providers", serverID: targetID)
        let response = try decodeJSON(PlexMediaProvidersResponse.self, from: data, serverID: targetID)
        return response.MediaContainer.MediaProvider?
            .compactMap(\.liveTVProvider)
            .first
    }

    func getLiveTVChannels(
        provider: PlexLiveTVProvider,
        serverID: String? = nil
    ) async throws -> [PlexLiveChannel] {
        let targetID = try resolveServerID(serverID ?? liveTVServerID)
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
            serverID: serverID ?? liveTVServerID
        )
        return makeLiveTVLineup(provider: provider, channels: channels, programs: programs)
    }

    func getLiveTVGuide(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel],
        date: Date,
        serverID: String? = nil
    ) async throws -> PlexLiveTVLineup {
        let dateValue = Self.liveTVDateFormatter.string(from: date)
        var programs: [PlexLiveProgram] = []

        // Plex accepts several repeated channel keys. Keeping batches modest
        // avoids oversized URLs on lineups with hundreds of stations.
        for batchStart in stride(from: 0, to: channels.count, by: 20) {
            let batchEnd = min(batchStart + 20, channels.count)
            let batch = channels[batchStart..<batchEnd]
            var queryItems = batch.map {
                URLQueryItem(name: "channelGridKey", value: $0.gridKey)
            }
            queryItems.append(URLQueryItem(name: "date", value: dateValue))

            let batchPrograms: [PlexLiveProgram] = try await fetchMetadata(
                path: provider.gridKey,
                queryItems: queryItems,
                serverID: serverID ?? liveTVServerID
            )
            programs.append(contentsOf: batchPrograms)
        }

        return makeLiveTVLineup(provider: provider, channels: channels, programs: programs)
    }

    func tuneLiveTV(
        provider: PlexLiveTVProvider,
        channel: PlexLiveChannel,
        serverID: String? = nil
    ) async throws -> PlexLiveTuneResult {
        let targetID = try resolveServerID(serverID ?? liveTVServerID)
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

    private func makeLiveTVLineup(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel],
        programs: [PlexLiveProgram]
    ) -> PlexLiveTVLineup {
        let programsByChannel = Dictionary(grouping: programs) { program in
            program.channelGridKey ?? program.channelIdentifier ?? ""
        }
        let guides = channels.map { channel in
            let channelPrograms = (
                programsByChannel[channel.gridKey]
                    ?? programsByChannel[channel.id]
                    ?? []
            ).sorted {
                ($0.beginsAt ?? .distantPast) < ($1.beginsAt ?? .distantPast)
            }
            return PlexLiveChannelGuide(channel: channel, programs: channelPrograms)
        }
        return PlexLiveTVLineup(provider: provider, guides: guides)
    }

    private static func channelSortKey(_ channel: PlexLiveChannel) -> [Int] {
        let components = (channel.vcn ?? channel.id)
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        return components.isEmpty ? [Int.max] : components
    }

    private static let liveTVDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
