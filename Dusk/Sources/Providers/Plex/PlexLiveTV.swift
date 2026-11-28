import Foundation

/// Plex's `LiveTVProviding`: the DVR from `/media/providers`, its channel
/// lineup and tuner devices (`/livetv/dvrs/{id}`), the guide grid, on-now
/// (`watchnow`), recordings by guid (`/library/all`) and the tune
/// (`/livetv/dvrs/{id}/channels/{channel}/tune`).
///
/// Every request goes to `serverID` through `transport`; nil means the
/// transport's fallback, the highest-priority server.
struct PlexLiveTV: LiveTVProviding {
    let serverID: String?
    /// nil on the value `PlexServerProvider.liveTV` hands out, which then
    /// throws `noServerConnected`; see `PlexLiveTVTransport`.
    let transport: (any PlexLiveTVTransport)?

    // MARK: - Source, channels, devices

    @MainActor func source() async throws -> LiveTVProvider? {
        let transport = try routed()
        let targetID = try transport.resolveServerID(serverID)
        // A timeout above `requestResourceTimeout` sends this through
        // `slowQuerySession`, i.e. its own connections to the server: on a big
        // library Home's slow reads can fill the shared session's, and a cheap
        // `/media/providers` queued behind them used up its 30s (1.7.2). That
        // session's 120s budget is what ends a hung answer (measured; the 45s
        // itself does not cut it off); `LiveTVViewModel.discover()` then asks
        // again.
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/media/providers",
            queryItems: nil,
            timeoutInterval: Self.discoveryTimeout,
            serverID: targetID
        )
        let response = try transport.decodeJSON(PlexMediaProvidersResponse.self, from: data, serverID: targetID)
        return response.MediaContainer.MediaProvider?
            .compactMap { PlexLiveTVMapper.provider($0, serverID: targetID) }
            .first
    }

    @MainActor func channels(of source: LiveTVProvider) async throws -> [LiveChannel] {
        let transport = try routed()
        let targetID = try transport.resolveServerID(serverID)
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: source.channelsKey,
            queryItems: nil,
            timeoutInterval: nil,
            serverID: targetID
        )
        let response = try transport.decodeJSON(PlexLiveChannelsResponse.self, from: data, serverID: targetID)
        return (response.MediaContainer.Channel ?? []).map(PlexLiveTVMapper.channel).sorted {
            Self.channelSortKey($0).lexicographicallyPrecedes(Self.channelSortKey($1))
        }
    }

    @MainActor func devices(of source: LiveTVProvider) async throws -> [LiveTVDevice] {
        let transport = try routed()
        let targetID = try transport.resolveServerID(serverID)
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/livetv/dvrs/\(source.dvrID)",
            queryItems: nil,
            timeoutInterval: nil,
            serverID: targetID
        )
        return PlexLiveTVMapper.devices(try transport.decodeJSON(PlexLiveTVDVRResponse.self, from: data, serverID: targetID))
    }

    // MARK: - Guide

    @MainActor func onNow(source: LiveTVProvider, channels: [LiveChannel]) async throws -> LiveTVLineup {
        let programs: [PlexLiveProgramDTO] = try await metadata(path: source.watchNowKey, queryItems: nil)
        return lineup(source: source, channels: channels, programs: programs.map(PlexLiveTVMapper.program))
    }

    /// One request for every channel: the grid takes a time range
    /// (`endsAt>` / `beginsAt<`) the way Plex Web asks for its guide, and then
    /// answers for all channels at once. A day's range costs one request
    /// however many channels there are, where `date=` needs one per channel
    /// (see `guide(source:channels:days:)`).
    @MainActor func airings(source: LiveTVProvider, window: LiveTVGuideWindow) async throws -> [LiveProgram] {
        let programs: [PlexLiveProgramDTO] = try await metadata(
            path: source.gridKey,
            queryItems: [
                // Strict: an airing that ends right at the start is not in it.
                URLQueryItem(name: "endsAt>", value: String(Int(window.start.timeIntervalSince1970))),
                URLQueryItem(name: "beginsAt<", value: String(Int(window.end.timeIntervalSince1970))),
            ]
        )
        return programs.map(PlexLiveTVMapper.program)
    }

    /// Programs that span midnight come back for both days; the lineup files
    /// each airing once.
    @MainActor func guide(source: LiveTVProvider, channels: [LiveChannel], days: [Date]) async throws -> LiveTVLineup {
        let dateValues = days.map { Self.dateFormatter.string(from: $0) }
        let requests = channels.flatMap { channel in dateValues.map { (channel, $0) } }

        // One request per channel: the grid answers only for the LAST of
        // repeated `channelGridKey` values (XMLTV and cloud guides alike), so
        // batching left every channel but one per batch empty (issue #17).
        // A few run at a time so long lineups stay quick.
        let results = await withTaskGroup(of: Result<[LiveProgram], Error>.self) { group in
            var pending = requests.makeIterator()
            for _ in 0..<Self.guideConcurrency {
                guard let (channel, dateValue) = pending.next() else { break }
                group.addTask {
                    await self.gridPrograms(source: source, channel: channel, date: dateValue)
                }
            }
            var results: [Result<[LiveProgram], Error>] = []
            for await result in group {
                results.append(result)
                if let (channel, dateValue) = pending.next() {
                    group.addTask {
                        await self.gridPrograms(source: source, channel: channel, date: dateValue)
                    }
                }
            }
            return results
        }

        // A channel whose guide failed keeps an empty (still tunable) row;
        // only a guide that failed for every channel is an error.
        var programs: [LiveProgram] = []
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

        return lineup(source: source, channels: channels, programs: programs)
    }

    func lineup(source: LiveTVProvider, channels: [LiveChannel], programs: [LiveProgram]) -> LiveTVLineup {
        LiveTVLineup(provider: source, channels: channels, programs: programs)
    }

    @MainActor private func gridPrograms(
        source: LiveTVProvider,
        channel: LiveChannel,
        date: String
    ) async -> Result<[LiveProgram], Error> {
        do {
            let programs: [PlexLiveProgramDTO] = try await metadata(
                path: source.gridKey,
                queryItems: [
                    URLQueryItem(name: "channelGridKey", value: channel.gridKey),
                    URLQueryItem(name: "date", value: date),
                ]
            )
            return .success(programs.map(PlexLiveTVMapper.program))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Recordings

    /// Matched by the airing's metadata guid the way Plex matches recordings.
    /// Nil when the airing has no guid or nothing in the library carries it.
    /// Plex has no catch-up of its own: a past airing plays only from such a
    /// recording.
    @MainActor func recording(for program: LiveProgram, source: LiveTVProvider) async throws -> MediaItem? {
        guard let guid = program.guid?.nilIfEmpty, let serverID else { return nil }
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/library/all",
            queryItems: [
                URLQueryItem(name: "guid", value: guid),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            timeoutInterval: nil,
            serverID: serverID
        )
        let items = (try transport.decodeJSON(MetadataResponse<PlexItemDTO>.self, from: data, serverID: serverID)
            .MediaContainer.Metadata ?? [])
            .map { PlexItemMapper.map($0, serverID: serverID) }
        return items.first { item in
            item.type == .episode || item.type == .movie
                ? program.type == .unknown || item.type == program.type
                : false
        }
    }

    // MARK: - Tune

    /// The live session itself when the tuned stream plays in AVPlayer as is
    /// (`allowsDirectPlay`, see `TuneMedia.supportsLiveDirectPlay`), otherwise
    /// a Plex transcode.
    @MainActor func tune(
        _ channel: LiveChannel,
        source: LiveTVProvider,
        allowsDirectPlay: Bool
    ) async throws -> LiveTuneResult {
        let transport = try routed()
        let targetID = try transport.resolveServerID(serverID)
        let path = "/livetv/dvrs/\(source.dvrID)/channels/\(channel.tuneIdentifier)/tune"
        let playbackSessionIdentifier = UUID().uuidString
        let data = try await transport.rawServerRequest(
            method: "POST",
            path: path,
            queryItems: [
                URLQueryItem(
                    name: "X-Plex-Session-Identifier",
                    value: playbackSessionIdentifier
                ),
            ],
            timeoutInterval: nil,
            serverID: targetID
        )
        let response = try transport.decodeJSON(PlexLiveTuneResponse.self, from: data, serverID: targetID)
        guard let tuned = response.MediaContainer.tunedSession,
              let sessionID = tuned.sessionID else {
            let message = response.MediaContainer.tuneFailureMessage
                ?? "Plex did not return a Live TV session."
            throw PlexServiceError.serverMessage(message)
        }

        let sessionPath = tuned.sessionPath
        let media = tuned.media.map { PlexLiveTVMapper.media($0, sessionPath: sessionPath) }
            ?? Self.fallbackMedia(sessionPath: sessionPath)
        guard let part = media.firstAvailablePart else {
            throw PlexServiceError.decodingError("Plex did not return a playable Live TV stream.")
        }
        let reportKey = Self.sessionReportKey(sessionID: sessionID)

        if allowsDirectPlay,
           tuned.media?.supportsLiveDirectPlay == true,
           let directURL = await transport.liveTVDirectPlayURL(
            sessionPath: sessionPath,
            sessionIdentifier: playbackSessionIdentifier,
            serverID: targetID
           ) {
            return LiveTuneResult(
                serverID: targetID,
                sessionID: sessionID,
                reportKey: reportKey,
                playbackSessionIdentifier: playbackSessionIdentifier,
                transcodeSessionID: nil,
                playbackURL: directURL,
                media: media,
                part: part,
                isDirectPlay: true
            )
        }

        let requestedTranscodeSessionID = UUID().uuidString
        let liveStream = try await transport.liveTVTranscodeStream(
            sessionPath: sessionPath,
            sessionIdentifier: playbackSessionIdentifier,
            transcodeSessionID: requestedTranscodeSessionID,
            serverID: targetID
        )

        let playbackURL: URL
        let transcodeSessionID: String?
        switch liveStream {
        case .transcode(let url):
            playbackURL = url
            transcodeSessionID = requestedTranscodeSessionID
        case .directPlayOnly:
            let streamPath = tuned.playbackPath
                ?? "\(sessionPath)/\(transport.clientIdentifier)/index.m3u8"
            guard let directURL = transport.liveTVTokenizedURL(path: streamPath, serverID: targetID) else {
                throw PlexServiceError.invalidURL
            }
            playbackURL = directURL
            transcodeSessionID = nil
        case .failed(let message):
            throw PlexServiceError.decodingError(
                message?.nilIfEmpty ?? "Plex could not create a Live TV stream."
            )
        }

        return LiveTuneResult(
            serverID: targetID,
            sessionID: sessionID,
            reportKey: reportKey,
            playbackSessionIdentifier: playbackSessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            playbackURL: playbackURL,
            media: media,
            part: part
        )
    }

    /// The `key` a live session's timeline reports carry.
    static func sessionReportKey(sessionID: String) -> String {
        "/livetv/sessions/\(sessionID)"
    }

    private static func fallbackMedia(sessionPath: String) -> MediaVersion {
        let part = MediaPart(
            id: "0",
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
        return MediaVersion(
            id: "0",
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

    // MARK: - Requests

    /// `MediaContainer.Metadata` of `path` on this server.
    @MainActor private func metadata<T: Decodable>(path: String, queryItems: [URLQueryItem]?) async throws -> [T] {
        let transport = try routed()
        let targetID = try transport.resolveServerID(serverID)
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: targetID
        )
        let response = try transport.decodeJSON(MetadataResponse<T>.self, from: data, serverID: targetID)
        return response.MediaContainer.Metadata ?? []
    }

    @MainActor private func routed() throws -> any PlexLiveTVTransport {
        guard let transport else { throw PlexServiceError.noServerConnected }
        return transport
    }

    private static func channelSortKey(_ channel: LiveChannel) -> [Int] {
        let components = (channel.vcn ?? channel.id)
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        return components.isEmpty ? [Int.max] : components
    }

    private static let guideConcurrency = 6

    /// How long `/media/providers` may take (see `source()`).
    static let discoveryTimeout: TimeInterval = 45

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// What a live session's server stream came back as.
enum PlexLiveTVStream: Sendable {
    /// A transcode consumer at this URL.
    case transcode(URL)
    /// The server will only direct play the session.
    case directPlayOnly
    case failed(String?)
}

/// How the Plex Live TV facet reaches its server for now.
///
/// Routing, the token refresh and self-healing still live in
/// `MediaService+Networking` (05-plan P0-06), and a provider is built without
/// any of them, so the facade builds this facet itself with itself as the
/// transport (`MediaService.liveTV(for:)`). The two live-stream calls are the
/// playback facet's (`MediaService+Streams`). Once the pool owns recovery
/// (04 §8, P0-16) the facet sends through `PlexClient` and the facade routes
/// through `session.provider.liveTV`.
@MainActor
protocol PlexLiveTVTransport: PlexServerTransport {
    var clientIdentifier: String { get }

    /// The id itself, or the highest-priority server for nil.
    func resolveServerID(_ serverID: String?) throws -> String

    /// A direct play of the tuned session's own HLS, or nil when the server
    /// does not offer one.
    func liveTVDirectPlayURL(sessionPath: String, sessionIdentifier: String, serverID: String) async -> URL?

    /// A server stream consumer for the tuned session.
    func liveTVTranscodeStream(
        sessionPath: String,
        sessionIdentifier: String,
        transcodeSessionID: String,
        serverID: String
    ) async throws -> PlexLiveTVStream

    /// `path` on the server's current connection, with its token; nil without
    /// a connection.
    func liveTVTokenizedURL(path: String, serverID: String) -> URL?
}

extension PlexServerProvider {
    /// Not routed yet: see `PlexLiveTVTransport`. Nothing reads it in Phase 0;
    /// the facade uses `MediaService.liveTV(for:)`.
    var liveTV: (any LiveTVProviding)? { PlexLiveTV(serverID: descriptor.id, transport: nil) }
}
