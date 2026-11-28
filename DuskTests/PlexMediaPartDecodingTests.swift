import Foundation
import Testing
@testable import Dusk

@Suite("Plex media part decoding")
struct PlexMediaPartDecodingTests {
    private func part(_ json: String) throws -> MediaPart {
        MediaPart(plex: try JSONDecoder().decode(PlexMediaPartDTO.self, from: Data(json.utf8)))
    }

    @Test(arguments: ["audioChannelLayout", "channelLayout"])
    func surroundLayoutSurvivesPlexAndLegacyOfflineDecoding(key: String) throws {
        let json = """
        {"id":1,"key":"/fixture.mkv","Stream":[
          {"id":2,"streamType":2,"codec":"eac3","channels":6,"\(key)":"5.1(side)"}
        ]}
        """
        let part = try part(json)
        let stream = try #require(part.streams.first)
        #expect(stream.channelLayout == "5.1(side)")
        #expect(AudioTrack(stream: stream).channelLayout == "5.1(side)")
        let cached = try JSONEncoder().encode(stream)
        #expect(MediaStream(plex: try JSONDecoder().decode(PlexMediaStreamDTO.self, from: cached)).channelLayout == "5.1(side)")
        #expect(try JSONDecoder().decode(MediaStream.self, from: cached).channelLayout == "5.1(side)")
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

        let part = try part(json)

        #expect(part.streams.map(\.id) == ["175569", "175568", "175571"])
        #expect(part.streams.map(\.kind) == [.video, .audio, .subtitle])
    }

    /// The mapper carries Plex's renamed and grouped fields onto the domain
    /// names (`selected` → `isServerSelected`, `colorTrc` → `colorTransfer`,
    /// the four `DOVI*` fields → `dolbyVision`).
    @Test func streamFieldsMapOntoDomainNames() throws {
        let json = """
        {"id":"9","key":"/library/parts/9/file.mkv","accessible":"1","exists":0,"Stream":[
          {"id":1,"streamType":1,"codec":"hevc","colorTrc":"smpte2084","DOVIPresent":1,"DOVIProfile":8,
           "DOVILevel":6,"DOVIBLCompatID":1,"codecID":"hvc1"},
          {"id":2,"streamType":3,"codec":"srt","selected":1,"default":true,"forced":"1","hearingImpaired":0}
        ]}
        """
        let part = try part(json)
        #expect(part.accessible == true)
        #expect(part.exists == false)
        let video = part.streams[0]
        #expect(video.colorTransfer == "smpte2084")
        #expect(video.codecID == "hvc1")
        #expect(video.dolbyVision == DolbyVisionInfo(present: true, profile: 8, level: 6, blCompatID: 1))
        let subtitle = part.streams[1]
        #expect(subtitle.dolbyVision == nil)
        #expect(subtitle.isServerSelected == true)
        #expect(subtitle.isDefault == true)
        // `forced` is Bool or Int only; a string reads as unknown, as before.
        #expect(subtitle.isForced == nil)
        #expect(subtitle.isHearingImpaired == false)
    }

    /// A missing `value` drops the whole `Rating` array (the details decoder
    /// falls back to an empty list), as before the DTO split.
    @Test func ratingsMapAndRequireAValue() throws {
        let ratings = try JSONDecoder().decode(
            [PlexRatingDTO].self,
            from: Data(#"[{"image":"imdb://image.rating","value":7.9,"type":"audience"}]"#.utf8)
        ).map(Rating.init(plex:))
        #expect(ratings == [Rating(image: "imdb://image.rating", value: 7.9, type: "audience")])
        #expect((try? JSONDecoder().decode([PlexRatingDTO].self, from: Data(#"[{"image":"imdb://image.rating"}]"#.utf8))) == nil)
    }
}
