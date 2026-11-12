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
    let lineup: PlexLiveTVLineup
}

extension PlexLiveTVLineup {
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
                lineup: PlexLiveTVLineup(provider: provider, guides: guides)
            ))
        }
        let rest = guides.filter { !claimed.contains($0.channel.id) }
        if !rest.isEmpty {
            groups.append(PlexLiveTVDeviceLineup(
                id: "plex",
                title: provider.title,
                lineup: PlexLiveTVLineup(provider: provider, guides: rest)
            ))
        }
        return groups.count > 1 ? groups : nil
    }
}

/// `/livetv/dvrs/{id}`: the DVR with its devices and their channel mappings.
struct PlexLiveTVDVRResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Dvr: [Dvr]?
    }

    struct Dvr: Decodable {
        let Device: [Device]?
    }

    struct Device: Decodable {
        let key: String?
        let title: String?
        let make: String?
        let model: String?
        let ChannelMapping: [ChannelMapping]?

        private enum CodingKeys: String, CodingKey {
            case key, title, make, model, ChannelMapping
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = container.liveTVDeviceString(forKey: .key)
            title = container.liveTVDeviceString(forKey: .title)
            make = container.liveTVDeviceString(forKey: .make)
            model = container.liveTVDeviceString(forKey: .model)
            ChannelMapping = try? container.decodeIfPresent([PlexLiveTVDVRResponse.ChannelMapping].self, forKey: .ChannelMapping)
        }
    }

    struct ChannelMapping: Decodable {
        let channelKey: String?
        let enabled: Bool

        private enum CodingKeys: String, CodingKey {
            case channelKey, enabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            channelKey = container.liveTVDeviceString(forKey: .channelKey)
            enabled = container.liveTVDeviceString(forKey: .enabled) != "0"
        }
    }

    var devices: [PlexLiveTVDevice] {
        (MediaContainer.Dvr ?? []).flatMap { $0.Device ?? [] }.enumerated().compactMap { index, device in
            let keys = Set((device.ChannelMapping ?? []).filter(\.enabled).compactMap { $0.channelKey?.nilIfEmpty })
            guard !keys.isEmpty else { return nil }
            let title = device.title?.nilIfEmpty ?? device.model?.nilIfEmpty
                ?? device.make?.nilIfEmpty ?? "Tuner \(index + 1)"
            return PlexLiveTVDevice(id: device.key?.nilIfEmpty ?? "\(index)", title: title, channelKeys: keys)
        }
    }
}

private extension KeyedDecodingContainer {
    func liveTVDeviceString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? "1" : "0" }
        return nil
    }
}
