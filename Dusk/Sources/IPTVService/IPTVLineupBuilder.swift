import Foundation

/// Turns a parsed playlist and guide into the same `LiveTVLineup` the
/// Plex guide uses, so IPTV channels get the existing guide rows, Watch Live
/// card, now/next, program sheet and live player HUD with no parallel UI.
/// The channels carry `LiveChannel.iptv`, which is what keeps them away
/// from every Plex call.
enum IPTVLineupBuilder {
    static let providerIdentifier = "tv.dusk.iptv"

    static func provider(for source: IPTVSource) -> LiveTVProvider {
        LiveTVProvider(
            identifier: "iptv:\(source.id.uuidString)",
            providerIdentifier: providerIdentifier,
            title: source.name,
            dvrID: 0,
            gridKey: "",
            serverID: IPTVImages.serverID
        )
    }

    static func lineup(
        source: IPTVSource,
        playlist: IPTVPlaylist,
        guide: IPTVGuide,
        sourceHeaders: [String: String]
    ) -> LiveTVLineup {
        let resolver = GuideChannelResolver(guide: guide)
        var usedIDs = Set<String>()
        var guides: [LiveChannelGuide] = []
        let sourceIdentity = IPTVResumeKey.sourceIdentity(playlistURL: source.playlistURL)

        for (index, entry) in playlist.entries.enumerated() {
            var channelID = "iptv:\(source.id.uuidString):\(entry.tvgID ?? entry.streamURL.absoluteString)"
            if !usedIDs.insert(channelID).inserted {
                channelID += "#\(index)"
                usedIDs.insert(channelID)
            }
            let guideID = resolver.guideChannelID(for: entry)
            let logo = entry.logoURL ?? guideID.flatMap { guide.channels[$0]?.iconURL }

            var headers = sourceHeaders
            for (name, value) in entry.streamHeaders { headers[name] = value }
            if let referrer = entry.referrer { headers["Referer"] = referrer }

            let channel = LiveChannel(
                iptvID: channelID,
                number: entry.number,
                title: entry.title,
                logo: logo?.absoluteString,
                playable: IPTVPlayableChannel(
                    sourceID: source.id,
                    sourceIdentity: sourceIdentity,
                    streamURL: entry.streamURL,
                    headers: headers,
                    userAgent: entry.userAgent,
                    drm: entry.drm,
                    catchUp: entry.catchUp
                )
            )
            let programs = guideID.map { guide.programmes[$0] ?? [] } ?? []
            guides.append(LiveChannelGuide(
                channel: channel,
                programs: programs.map { LiveProgram(iptv: $0, channel: channel) }
            ))
        }
        return LiveTVLineup(provider: provider(for: source), guides: guides)
    }

    /// How many days back the guide has to reach for this playlist: the
    /// longest catch-up window of any entry, 0 when none has catch-up.
    static func catchUpDays(for playlist: IPTVPlaylist) -> Int {
        playlist.entries.compactMap(\.catchUp?.days).max() ?? 0
    }

    /// What of the XMLTV file is worth keeping while parsing: every
    /// `tvg-id`, plus every entry's `tvg-name` and title for the display-name
    /// match. Never "everything": a provider's guide covers far more channels
    /// than one playlist (and an Xtream list's VOD rows have no `tvg-id`).
    static func guideChannelFilter(for playlist: IPTVPlaylist) -> (ids: Set<String>, names: Set<String>) {
        var ids = Set<String>()
        var names = Set<String>()
        for entry in playlist.entries {
            if let id = entry.tvgID { ids.insert(id) }
            for name in [entry.tvgName, entry.title].compactMap({ $0 }) {
                let normalized = GuideChannelResolver.normalized(name)
                if !normalized.isEmpty { names.insert(normalized) }
            }
        }
        return (ids, names)
    }

    /// `tvg-id` first (exactly, then ignoring case), then the entry's
    /// `tvg-name` or title against the guide's display names — only when that
    /// name is unambiguous.
    private struct GuideChannelResolver {
        let guide: IPTVGuide
        private var byLowercasedID: [String: String] = [:]
        private var byName: [String: [String]] = [:]

        init(guide: IPTVGuide) {
            self.guide = guide
            let ids = Set(guide.channels.keys).union(guide.programmes.keys)
            for id in ids {
                byLowercasedID[id.lowercased()] = id
            }
            for channel in guide.channels.values {
                for name in Set(channel.displayNames.map(Self.normalized)) where !name.isEmpty {
                    byName[name, default: []].append(channel.id)
                }
            }
        }

        func guideChannelID(for entry: IPTVPlaylistEntry) -> String? {
            if let id = entry.tvgID {
                if guide.programmes[id] != nil || guide.channels[id] != nil { return id }
                if let match = byLowercasedID[id.lowercased()] { return match }
            }
            for name in [entry.tvgName, entry.title].compactMap({ $0 }) {
                if let ids = byName[Self.normalized(name)], ids.count == 1 { return ids[0] }
            }
            return entry.tvgID
        }

        static func normalized(_ name: String) -> String {
            XMLTVParser.normalizedName(name)
        }
    }
}

extension LiveChannel {
    init(iptvID: String, number: String?, title: String, logo: String?, playable: IPTVPlayableChannel) {
        self.init(
            id: iptvID,
            gridKey: iptvID,
            vcn: number,
            isHD: false,
            thumb: logo,
            title: title,
            callSign: nil,
            language: nil,
            alternateIdentifiers: [],
            iptv: playable
        )
    }

    var isIPTV: Bool { iptv != nil }
}

extension LiveProgram {
    /// XMLTV `title` is the show and `sub-title` the episode, while Plex puts
    /// the episode in `title` and the show in `grandparentTitle`; mapped so
    /// the shared guide reads both the same way.
    init(iptv programme: IPTVProgramme, channel: LiveChannel) {
        let start = Int(programme.start.timeIntervalSince1970)
        let title: String
        let grandparentTitle: String?
        if let subtitle = programme.subtitle?.nilIfEmpty, subtitle != programme.title {
            title = subtitle
            grandparentTitle = programme.title.nilIfEmpty
        } else {
            title = programme.title
            grandparentTitle = nil
        }
        self.init(
            itemID: "iptv-\(channel.id)-\(start)",
            key: nil,
            guid: nil,
            title: title,
            summary: programme.summary,
            thumb: programme.iconURL?.absoluteString,
            art: nil,
            grandparentTitle: grandparentTitle,
            parentTitle: nil,
            type: .unknown,
            duration: Int(programme.stop.timeIntervalSince(programme.start) * 1000),
            airings: [LiveAiring(
                beginsAt: programme.start.timeIntervalSince1970,
                endsAt: programme.stop.timeIntervalSince1970,
                channel: channel
            )]
        )
    }
}

extension LiveAiring {
    init(beginsAt: TimeInterval, endsAt: TimeInterval, channel: LiveChannel) {
        self.init(
            id: nil,
            beginsAt: beginsAt,
            endsAt: endsAt,
            channelID: nil,
            channelIdentifier: channel.id,
            channelThumb: channel.thumb,
            channelTitle: channel.title,
            channelVCN: channel.vcn,
            channelCallSign: nil,
            gridKey: channel.gridKey,
            videoResolution: nil
        )
    }
}

extension LiveTVProvider {
    var isIPTV: Bool { providerIdentifier == IPTVLineupBuilder.providerIdentifier }
}

extension LivePlaybackContext {
    var isIPTV: Bool { channel.iptv != nil }
}
