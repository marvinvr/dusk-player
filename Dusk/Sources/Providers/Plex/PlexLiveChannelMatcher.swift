import Foundation

// Plex's filing of guide airings under lineup channels. Plex-private: IPTV
// files its own (`IPTVLineupBuilder`), and other servers name an airing's
// channel by id. Feature code reaches it through the Live TV facet
// (`LiveTVProviding.lineup(source:channels:programs:)`).

extension LiveTVLineup {
    /// Files guide programs under the lineup's channels. Every channel gets a
    /// guide, empty when nothing matched, so it stays listed and tunable.
    init(
        provider: LiveTVProvider,
        channels: [LiveChannel],
        programs: [LiveProgram]
    ) {
        let matcher = PlexLiveChannelMatcher(channels: channels)
        var programsByChannel: [String: [LiveProgram]] = [:]
        var seenIDs: [String: Set<String>] = [:]
        for program in programs.flatMap({ $0.splitByAiring() }) {
            guard let airing = program.primaryAiring,
                  let channel = matcher.channel(for: airing),
                  seenIDs[channel.id, default: []].insert(program.id).inserted else { continue }
            programsByChannel[channel.id, default: []].append(program)
        }
        self.init(
            provider: provider,
            guides: channels.map { channel in
                LiveChannelGuide(
                    channel: channel,
                    programs: (programsByChannel[channel.id] ?? []).sorted {
                        ($0.beginsAt ?? .distantPast) < ($1.beginsAt ?? .distantPast)
                    }
                )
            }
        )
    }
}

/// Decides which lineup channel a guide airing belongs to. Providers disagree
/// on which field ties the two together: cloud and XMLTV guides carry the
/// channel's `gridKey`, others only an identifier, a channel number or a call
/// sign (issue #17: an HDHomeRun lineup listed every channel with no programs).
/// Identifiers are tried first; the descriptive keys only count when they
/// name exactly one channel, since subchannels often share a call sign or a
/// network title.
struct PlexLiveChannelMatcher {
    private let channels: [LiveChannel]
    private var byIdentifier: [String: Int] = [:]
    private var byNumber: [String: [Int]] = [:]
    private var byCallSign: [String: [Int]] = [:]
    private var byTitle: [String: [Int]] = [:]

    init(channels: [LiveChannel]) {
        self.channels = channels
        for (index, channel) in channels.enumerated() {
            for identifier in [channel.gridKey, channel.id] + channel.alternateIdentifiers {
                if byIdentifier[identifier] == nil {
                    byIdentifier[identifier] = index
                }
            }
            if let number = Self.normalizedNumber(channel.vcn) {
                byNumber[number, default: []].append(index)
            }
            if let callSign = Self.normalizedName(channel.callSign) {
                byCallSign[callSign, default: []].append(index)
            }
            if let title = Self.normalizedName(channel.title) {
                byTitle[title, default: []].append(index)
            }
        }
    }

    func channel(for airing: LiveAiring) -> LiveChannel? {
        let identifiers = [airing.gridKey, airing.channelIdentifier, airing.channelID.map(String.init)]
            .compactMap { $0?.nilIfEmpty }
        if let index = identifiers.lazy.compactMap({ byIdentifier[$0] }).first {
            return channels[index]
        }
        let candidates = [
            Self.normalizedNumber(airing.channelVCN).flatMap { byNumber[$0] },
            Self.normalizedName(airing.channelCallSign).flatMap { byCallSign[$0] },
            Self.normalizedName(airing.channelTitle).flatMap { byTitle[$0] },
        ]
        if let match = candidates.lazy.compactMap({ $0 }).first(where: { $0.count == 1 }) {
            return channels[match[0]]
        }
        return nil
    }

    /// "3.1", "3-1" and " 03.1 " are the same ATSC subchannel.
    private static func normalizedNumber(_ value: String?) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        let parts = value
            .split(whereSeparator: { !$0.isNumber })
            .map { String(Int($0) ?? 0) }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }

    private static func normalizedName(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
    }
}
