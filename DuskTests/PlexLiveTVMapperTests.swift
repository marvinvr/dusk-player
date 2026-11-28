import Foundation
import Testing
@testable import Dusk

/// Plex Live TV DTOs decode leniently and `PlexLiveTVMapper` fills the
/// gaps: the mapped `Live*` values must match what the domain types used to
/// decode on their own.
@Suite("Plex Live TV mapping")
struct PlexLiveTVMapperTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func channelFallsBackAcrossIdentifiers() throws {
        let channels = try decode([PlexLiveChannelDTO].self, """
        [{ "id": 7, "channelVcn": "7.1", "isHd": "1", "identifier": "ident", "key": "",
           "title": "Seven", "callSign": "KSEV" },
         { "gridKey": "g2", "vcn": "2", "isHd": 0 }]
        """).map(PlexLiveTVMapper.channel)

        #expect(channels[0].id == "7")
        #expect(channels[0].gridKey == "7")
        #expect(channels[0].vcn == "7.1")
        #expect(channels[0].isHD)
        #expect(channels[0].alternateIdentifiers == ["ident"])
        #expect(channels[0].title == "Seven")
        #expect(channels[0].callSign == "KSEV")
        #expect(channels[0].iptv == nil)

        #expect(channels[1].id == "g2")
        #expect(channels[1].gridKey == "g2")
        #expect(channels[1].vcn == "2")
        #expect(!channels[1].isHD)
        #expect(channels[1].title == "")
        #expect(channels[1].alternateIdentifiers.isEmpty)
    }

    @Test func programAndAiringsMapWithFallbacks() throws {
        let program = PlexLiveTVMapper.program(try decode(PlexLiveProgramDTO.self, """
        { "ratingKey": 42, "guid": 5, "title": "Pilot", "grandparentTitle": "Show", "type": "episode",
          "duration": "1800000",
          "Media": [{ "id": "9", "beginsAt": "100", "channelID": 3, "channelVcn": 4, "gridKey": "g1" },
                    { "beginsAt": 200.5, "endsAt": 300 }] }
        """))

        #expect(program.itemID == "42")
        #expect(program.guid == nil)
        #expect(program.title == "Pilot")
        #expect(program.seriesTitle == "Show")
        #expect(program.type == .episode)
        #expect(program.duration == 1_800_000)
        #expect(program.airings.count == 2)
        let first = try #require(program.airings.first)
        #expect(first.id == 9)
        #expect(first.beginsAt == 100)
        #expect(first.endsAt == 100)
        #expect(first.channelID == 3)
        #expect(first.channelVCN == "4")
        #expect(first.gridKey == "g1")
        #expect(program.airings[1].beginsAt == 200.5)
        #expect(program.airings[1].endsAt == 300)
    }

    @Test func programWithoutRatingKeyUsesItsKey() throws {
        let program = PlexLiveTVMapper.program(try decode(PlexLiveProgramDTO.self, """
        { "key": "/library/metadata/1", "type": "somethingNew" }
        """))
        #expect(program.itemID == "/library/metadata/1")
        #expect(program.title == "")
        #expect(program.type == .unknown)
        #expect(program.airings.isEmpty)
    }

    @Test func liveTVProviderIsStampedWithTheServer() throws {
        let response = try decode(PlexMediaProvidersResponse.self, """
        {"MediaContainer":{"MediaProvider":[
          {"identifier":"com.plexapp.plugins.library","protocols":"stream,download"},
          {"id":"5","parentID":"2","identifier":"tv.plex.providers.epg.cloud:2","title":"Antenna",
           "protocols":"livetv","Feature":[{"type":"grid","key":"/tv.plex.providers.epg.cloud:2/grid"},{"type":null}]}]}}
        """)
        let providers = (response.MediaContainer.MediaProvider ?? [])
            .compactMap { PlexLiveTVMapper.provider($0, serverID: "server-a") }

        #expect(providers.count == 1)
        let provider = try #require(providers.first)
        #expect(provider.identifier == "tv.plex.providers.epg.cloud:2")
        #expect(provider.providerIdentifier == "tv.plex.providers.epg.cloud")
        #expect(provider.title == "Antenna")
        #expect(provider.dvrID == 2)
        #expect(provider.gridKey == "/tv.plex.providers.epg.cloud:2/grid")
        #expect(provider.serverID == "server-a")
    }

    @Test func devicesKeepOnlyEnabledMappings() throws {
        let response = try decode(PlexLiveTVDVRResponse.self, """
        {"MediaContainer":{"Dvr":[{"Device":[
          {"key":"14","model":"HDHR5","ChannelMapping":[{"channelKey":"1000","enabled":"1"},{"channelKey":1001,"enabled":0}]},
          {"key":"15","title":"Threadfin","ChannelMapping":[{"channelKey":"2000","enabled":false}]},
          {"ChannelMapping":[{"channelKey":"3000"}]}]}]}}
        """)
        let devices = PlexLiveTVMapper.devices(response)

        #expect(devices.map(\.id) == ["14", "2"])
        #expect(devices.map(\.title) == ["HDHR5", "Tuner 3"])
        #expect(devices.first?.channelKeys == ["1000"])
        #expect(devices.last?.channelKeys == ["3000"])
    }
}
