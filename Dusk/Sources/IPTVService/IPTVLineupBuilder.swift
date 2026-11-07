import Foundation

/// Turns a parsed playlist and guide into the same `PlexLiveTVLineup` the
/// Plex guide uses, so IPTV channels get the existing guide rows, Watch Live
/// card, now/next, program sheet and live player HUD with no parallel UI.
/// The channels carry `PlexLiveChannel.iptv`, which is what keeps them away
/// from every Plex call.
enum IPTVLineupBuilder {
    static let providerIdentifier = "tv.dusk.iptv"

    static func provider(for source: IPTVSource) -> PlexLiveTVProvider {
        PlexLiveTVProvider(
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
    ) -> PlexLiveTVLineup {
        let resolver = GuideChannelResolver(guide: guide)
        var usedIDs = Set<String>()
        var guides: [PlexLiveChannelGuide] = []

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

            let channel = PlexLiveChannel(
                iptvID: channelID,
                number: entry.number,
                title: entry.title,
                logo: logo?.absoluteString,
                playable: IPTVPlayableChannel(
                    sourceID: source.id,
                    streamURL: entry.streamURL,
                    headers: headers,
                    userAgent: entry.userAgent,
                    drm: entry.drm
                )
            )
            let programs = guideID.map { guide.programmes[$0] ?? [] } ?? []
            guides.append(PlexLiveChannelGuide(
                channel: channel,
                programs: programs.map { PlexLiveProgram(iptv: $0, channel: channel) }
            ))
        }
        return PlexLiveTVLineup(provider: provider(for: source), guides: guides)
    }

    /// XMLTV channel ids worth keeping while parsing, or nil when some entry
    /// can only be matched by name (then every channel has to be read).
    static func wantedGuideChannelIDs(for playlist: IPTVPlaylist) -> Set<String>? {
        var ids = Set<String>()
        for entry in playlist.entries {
            guard let id = entry.tvgID else { return nil }
            ids.insert(id)
        }
        return ids
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
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

extension PlexLiveChannel {
    init(iptvID: String, number: String?, title: String, logo: String?, playable: IPTVPlayableChannel) {
        id = iptvID
        gridKey = iptvID
        vcn = number
        isHD = false
        thumb = logo
        self.title = title
        callSign = nil
        language = nil
        alternateIdentifiers = []
        iptv = playable
    }

    var isIPTV: Bool { iptv != nil }
}

extension PlexLiveAiring {
    init(beginsAt: TimeInterval, endsAt: TimeInterval, channel: PlexLiveChannel) {
        id = nil
        self.beginsAt = beginsAt
        self.endsAt = endsAt
        channelID = nil
        channelIdentifier = channel.id
        channelThumb = channel.thumb
        channelTitle = channel.title
        channelVCN = channel.vcn
        channelCallSign = nil
        gridKey = channel.gridKey
        videoResolution = nil
    }
}

extension PlexLiveTVProvider {
    var isIPTV: Bool { providerIdentifier == IPTVLineupBuilder.providerIdentifier }
}

extension PlexLivePlaybackContext {
    var isIPTV: Bool { channel.iptv != nil }
}
