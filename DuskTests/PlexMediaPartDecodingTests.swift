import Foundation
import Testing
@testable import Dusk

@Suite("Plex media part decoding")
struct PlexMediaPartDecodingTests {
    @Test(arguments: ["audioChannelLayout", "channelLayout"])
    func surroundLayoutSurvivesPlexAndLegacyOfflineDecoding(key: String) throws {
        let json = """
        {"id":1,"key":"/fixture.mkv","Stream":[
          {"id":2,"streamType":2,"codec":"eac3","channels":6,"\(key)":"5.1(side)"}
        ]}
        """
        let part = try JSONDecoder().decode(PlexMediaPart.self, from: Data(json.utf8))
        let stream = try #require(part.streams.first)
        #expect(stream.channelLayout == "5.1(side)")
        #expect(AudioTrack(stream: stream).channelLayout == "5.1(side)")
        let cached = try JSONEncoder().encode(stream)
        #expect(try JSONDecoder().decode(PlexStream.self, from: cached).channelLayout == "5.1(side)")
    }

    /// Plex can omit `id` on a stream (seen on an embedded EIA-608 caption
    /// track); that stream is dropped instead of failing the whole item.
    @Test func streamWithoutIDOrUnknownTypeIsDroppedNotFatal() throws {
        let json = """
        {
            "id": 1,
            "key": "/library/parts/1/file.mkv",
            "container": "mkv",
            "Stream": [
                { "id": 175569, "streamType": 1, "codec": "h264" },
                { "id": 175568, "streamType": 2, "codec": "eac3", "channels": 6 },
                { "streamType": 3, "codec": "eia_608", "embeddedInVideo": "1" },
                { "id": 175572, "streamType": 9, "codec": "unknown" },
                { "id": 175571, "streamType": 3, "codec": "srt", "key": "/library/streams/175571" }
            ]
        }
        """

        let part = try JSONDecoder().decode(PlexMediaPart.self, from: Data(json.utf8))

        #expect(part.streams.map(\.id) == [175569, 175568, 175571])
        #expect(part.streams.map(\.streamType) == [.video, .audio, .subtitle])
    }
}
