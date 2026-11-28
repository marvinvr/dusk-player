import Foundation

/// Plex Live TV DTOs (`PlexLiveTVDTO.swift`) → the `Live*` domain types.
/// The fallbacks for missing ids and times live here, not in the decoders.
enum PlexLiveTVMapper {
    // MARK: Lineup and guide

    static func channel(_ dto: PlexLiveChannelDTO) -> LiveChannel {
        let id = dto.id ?? dto.gridKey ?? UUID().uuidString
        return LiveChannel(
            id: id,
            gridKey: dto.gridKey ?? dto.id ?? id,
            vcn: dto.vcn ?? dto.channelVcn,
            isHD: dto.isHD ?? false,
            thumb: dto.thumb,
            title: dto.title ?? "",
            callSign: dto.callSign,
            language: dto.language,
            alternateIdentifiers: [dto.identifier, dto.key].compactMap { $0?.nilIfEmpty }
        )
    }

    static func program(_ dto: PlexLiveProgramDTO) -> LiveProgram {
        LiveProgram(
            itemID: dto.ratingKey ?? dto.key ?? UUID().uuidString,
            key: dto.key,
            guid: dto.guid,
            title: dto.title ?? "",
            summary: dto.summary,
            thumb: dto.thumb,
            art: dto.art,
            grandparentTitle: dto.grandparentTitle,
            parentTitle: dto.parentTitle,
            type: dto.type ?? .unknown,
            duration: dto.duration,
            airings: (dto.airings ?? []).map(airing)
        )
    }

    static func airing(_ dto: PlexLiveAiringDTO) -> LiveAiring {
        let beginsAt = dto.beginsAt ?? 0
        return LiveAiring(
            id: dto.id,
            beginsAt: beginsAt,
            endsAt: dto.endsAt ?? beginsAt,
            channelID: dto.channelID,
            channelIdentifier: dto.channelIdentifier,
            channelThumb: dto.channelThumb,
            channelTitle: dto.channelTitle,
            channelVCN: dto.channelVCN,
            channelCallSign: dto.channelCallSign,
            gridKey: dto.gridKey,
            videoResolution: dto.videoResolution
        )
    }

    // MARK: Providers and devices

    /// The Live TV provider a `/media/providers` entry describes, stamped
    /// with the server that answered. Nil for any other kind of provider.
    static func provider(_ dto: PlexMediaProvidersResponse.Provider, serverID: String) -> LiveTVProvider? {
        guard dto.protocols?.lowercased().contains("livetv") == true,
              let identifier = dto.identifier,
              let gridKey = dto.Feature?.first(where: { $0.type == "grid" })?.key,
              let dvrID = dto.parentID ?? trailingIdentifier(in: identifier) ?? dto.id else {
            return nil
        }

        return LiveTVProvider(
            identifier: identifier,
            providerIdentifier: dto.providerIdentifier ?? identifier.components(separatedBy: ":").first ?? identifier,
            title: dto.title ?? "Live TV",
            dvrID: dvrID,
            gridKey: gridKey,
            serverID: serverID
        )
    }

    private static func trailingIdentifier(in identifier: String) -> Int? {
        identifier.split(separator: ":").last.flatMap { Int($0) }
    }

    /// The DVR's devices that have at least one enabled channel mapping.
    static func devices(_ response: PlexLiveTVDVRResponse) -> [PlexLiveTVDevice] {
        (response.MediaContainer.Dvr ?? []).flatMap { $0.Device ?? [] }.enumerated().compactMap { index, device in
            let keys = Set((device.ChannelMapping ?? []).filter(\.enabled).compactMap { $0.channelKey?.nilIfEmpty })
            guard !keys.isEmpty else { return nil }
            let title = device.title?.nilIfEmpty ?? device.model?.nilIfEmpty
                ?? device.make?.nilIfEmpty ?? "Tuner \(index + 1)"
            return PlexLiveTVDevice(id: device.key?.nilIfEmpty ?? "\(index)", title: title, channelKeys: keys)
        }
    }

    // MARK: Tune

    static func media(_ tune: PlexLiveTuneResponse.TuneMedia, sessionPath: String) -> MediaVersion {
        let convertedParts = (tune.Part ?? []).enumerated().map { index, part in
            self.part(part, id: index, sessionPath: sessionPath)
        }
        let fallbackPart = MediaPart(
            id: "0",
            key: sessionPath,
            file: nil,
            size: nil,
            container: tune.container ?? "mpegts",
            duration: tune.duration,
            videoProfile: nil,
            audioProfile: nil,
            accessible: true,
            exists: true,
            streams: []
        )

        return MediaVersion(
            id: String(tune.id ?? 0),
            container: tune.container ?? "hls",
            videoCodec: tune.videoCodec,
            audioCodec: tune.audioCodec,
            videoResolution: tune.videoResolution,
            videoProfile: nil,
            audioProfile: nil,
            audioChannels: tune.audioChannels,
            width: tune.width,
            height: tune.height,
            bitrate: tune.bitrate,
            duration: tune.duration,
            optimizedForStreaming: nil,
            parts: convertedParts.isEmpty ? [fallbackPart] : convertedParts
        )
    }

    private static func part(_ part: PlexLiveTuneResponse.TunePart, id fallbackID: Int, sessionPath: String) -> MediaPart {
        MediaPart(
            id: String(part.id ?? fallbackID),
            key: part.key ?? sessionPath,
            file: nil,
            size: nil,
            container: part.container ?? "mpegts",
            duration: part.duration,
            videoProfile: nil,
            audioProfile: nil,
            accessible: true,
            exists: true,
            streams: (part.Stream ?? []).enumerated().compactMap { index, stream in
                self.stream(stream, id: index)
            }
        )
    }

    private static func stream(_ stream: PlexLiveTuneResponse.TuneStream, id fallbackID: Int) -> MediaStream? {
        guard let kind = stream.kind, let type = StreamKind(rawValue: kind) else {
            return nil
        }

        return MediaStream(
            id: String(stream.id ?? stream.index ?? fallbackID),
            kind: type,
            codec: stream.codec,
            displayTitle: nil,
            extendedDisplayTitle: nil,
            language: nil,
            languageCode: nil,
            languageTag: nil,
            isSelected: nil,
            isDefault: nil,
            width: stream.width,
            height: stream.height,
            bitrate: stream.bitrate,
            frameRate: stream.frameRate,
            bitDepth: stream.bitDepth,
            colorSpace: nil,
            colorRange: nil,
            colorPrimaries: nil,
            colorTransfer: nil,
            chromaSubsampling: nil,
            profile: stream.profile,
            level: stream.level,
            doviPresent: nil,
            doviProfile: nil,
            doviLevel: nil,
            doviBLCompatID: nil,
            channels: stream.channels,
            channelLayout: stream.audioChannelLayout,
            samplingRate: stream.samplingRate,
            isForced: nil,
            isHearingImpaired: nil,
            key: nil
        )
    }
}
