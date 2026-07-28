import Foundation

extension PlexService {
    func getLiveTVProvider() async throws -> PlexLiveTVProvider? {
        let data = try await rawServerRequest(path: "/media/providers")
        let response = try decodeJSON(PlexMediaProvidersResponse.self, from: data)
        return response.MediaContainer.MediaProvider?
            .compactMap(\.liveTVProvider)
            .first
    }

    func getLiveTVChannels(provider: PlexLiveTVProvider) async throws -> [PlexLiveChannel] {
        let data = try await rawServerRequest(path: provider.channelsKey)
        let response = try decodeJSON(PlexLiveChannelsResponse.self, from: data)
        return (response.MediaContainer.Channel ?? []).sorted {
            Self.channelSortKey($0).lexicographicallyPrecedes(Self.channelSortKey($1))
        }
    }

    func getLiveTVNowPlaying(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel]
    ) async throws -> PlexLiveTVLineup {
        let programs: [PlexLiveProgram] = try await fetchMetadata(path: provider.watchNowKey)
        return makeLiveTVLineup(provider: provider, channels: channels, programs: programs)
    }

    func getLiveTVGuide(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel],
        date: Date
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
                queryItems: queryItems
            )
            programs.append(contentsOf: batchPrograms)
        }

        return makeLiveTVLineup(provider: provider, channels: channels, programs: programs)
    }

    func tuneLiveTV(
        provider: PlexLiveTVProvider,
        channel: PlexLiveChannel
    ) async throws -> PlexLiveTuneResult {
        let path = "/livetv/dvrs/\(provider.dvrID)/channels/\(channel.tuneIdentifier)/tune"
        let data = try await rawServerRequest(method: "POST", path: path)
        let response = try decodeJSON(PlexLiveTuneResponse.self, from: data)
        guard let tuned = response.MediaContainer.tunedMedia,
              let sessionID = tuned.uuid?.nilIfEmpty else {
            throw PlexServiceError.decodingError("Plex did not return a Live TV session.")
        }

        let sessionPath = "/livetv/sessions/\(sessionID)"
        let media = tuned.makeMedia(sessionPath: sessionPath)
        guard let part = media.firstAvailablePart else {
            throw PlexServiceError.decodingError("Plex did not return a playable Live TV stream.")
        }
        let streamPath = "\(sessionPath)/\(clientIdentifier)/index.m3u8"
        guard let baseURL = serverBaseURL,
              let playbackURL = buildURL(
                base: baseURL.absoluteString,
                path: streamPath,
                queryItems: preferredServerToken.map {
                    [URLQueryItem(name: "X-Plex-Token", value: $0)]
                }
              ) else {
            throw PlexServiceError.invalidURL
        }

        return PlexLiveTuneResult(
            sessionID: sessionID,
            playbackURL: playbackURL,
            media: media,
            part: part
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
