import Foundation

/// One tuner device of a server's Live TV source (on Plex an HDHomeRun, or an
/// emulation of one such as Threadfin or ErsatzTV) and the lineup channels
/// mapped to it (`LiveTVProviding.devices(of:)`). The guide shows each device
/// as its own section, the way it shows each IPTV source.
struct LiveTVDevice: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    /// The lineup's `LiveChannel.id`s this device carries.
    let channelKeys: Set<String>
}

/// A device's share of the server lineup: one guide section.
struct LiveTVDeviceLineup: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let lineup: LiveTVLineup
}

extension LiveTVLineup {
    /// The lineup split per device, in the server's device order, channels
    /// in lineup order. A channel no device claims stays in a last group
    /// under the provider's title. With fewer than two groups there is
    /// nothing to split: the one server section stays as it always was.
    ///
    /// The section ids (`plex-<device>`, `plex`) are view identity and keep
    /// their strings.
    func groupedByDevice(_ devices: [LiveTVDevice]) -> [LiveTVDeviceLineup]? {
        var claimed = Set<String>()
        var groups: [LiveTVDeviceLineup] = []
        for device in devices {
            let guides = guides.filter {
                device.channelKeys.contains($0.channel.id) && claimed.insert($0.channel.id).inserted
            }
            guard !guides.isEmpty else { continue }
            groups.append(LiveTVDeviceLineup(
                id: "plex-\(device.id)",
                title: device.title,
                lineup: LiveTVLineup(provider: provider, guides: guides)
            ))
        }
        let rest = guides.filter { !claimed.contains($0.channel.id) }
        if !rest.isEmpty {
            groups.append(LiveTVDeviceLineup(
                id: Self.serverSectionID,
                title: provider.title,
                lineup: LiveTVLineup(provider: provider, guides: rest)
            ))
        }
        return groups.count > 1 ? groups : nil
    }

    /// The id of the server lineup's one section (or its unclaimed rest).
    static let serverSectionID = "plex"
}
