import Foundation

/// One tuner device of a Plex DVR (an HDHomeRun, or an emulation of one such
/// as Threadfin or ErsatzTV) and the lineup channels mapped to it. The guide
/// shows each device as its own section, the way it shows each IPTV source.
struct PlexLiveTVDevice: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    /// `ChannelMapping.channelKey`s, which are the lineup's `Channel.id`s.
    let channelKeys: Set<String>
}

/// A device's share of the Plex lineup: one guide section.
struct PlexLiveTVDeviceLineup: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let lineup: LiveTVLineup
}

extension LiveTVLineup {
    /// The lineup split per device, in the server's device order, channels
    /// in lineup order. A channel no device claims stays in a last group
    /// under the provider's title. With fewer than two groups there is
    /// nothing to split: the one Plex section stays as it always was.
    func groupedByDevice(_ devices: [PlexLiveTVDevice]) -> [PlexLiveTVDeviceLineup]? {
        var claimed = Set<String>()
        var groups: [PlexLiveTVDeviceLineup] = []
        for device in devices {
            let guides = guides.filter {
                device.channelKeys.contains($0.channel.id) && claimed.insert($0.channel.id).inserted
            }
            guard !guides.isEmpty else { continue }
            groups.append(PlexLiveTVDeviceLineup(
                id: "plex-\(device.id)",
                title: device.title,
                lineup: LiveTVLineup(provider: provider, guides: guides)
            ))
        }
        let rest = guides.filter { !claimed.contains($0.channel.id) }
        if !rest.isEmpty {
            groups.append(PlexLiveTVDeviceLineup(
                id: "plex",
                title: provider.title,
                lineup: LiveTVLineup(provider: provider, guides: rest)
            ))
        }
        return groups.count > 1 ? groups : nil
    }
}
