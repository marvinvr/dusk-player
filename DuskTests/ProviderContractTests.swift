import Foundation
import Testing
@testable import Dusk

/// The provider contract suite (docs/jellyfin/04-architecture.md §5.5,
/// 05-plan.md J-00b): the same three titles, recorded from plex-demo and
/// jellyfin-demo (both servers read the same files), each mapped by its own
/// provider's mapper. The domain values must agree where the servers agree:
/// stream kinds and canonical codecs, duration within 1 s, external ids,
/// season and episode numbers.
///
/// Per-user server state (which track the server pre-selects, watch state)
/// and agent-dependent metadata (ratings, content-rating country, cast
/// count) legitimately differ and are not compared.
@Suite("Provider contract")
struct ProviderContractTests {
    enum Provider: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case plex, jellyfin
        var testDescription: String { rawValue }
    }

    struct Title: Sendable, CustomTestStringConvertible {
        let name: String
        let kind: MediaKind
        var testDescription: String { name }

        static let all = [
            Title(name: "knives-out", kind: .movie),
            Title(name: "dune-part-two", kind: .movie),
            Title(name: "the-office-s01e01", kind: .episode),
        ]
    }

    /// Codec spellings a provider's mapper still gets wrong. Plex passes its
    /// server's `dca` through for DTS where the domain vocabulary says `dts`
    /// (04 §4.2); the Plex mapper has no alias table yet. When it gains one,
    /// the `withKnownIssue` in `canonicalCodecs` stops recording an issue and
    /// fails, which is the signal to delete this entry.
    static let knownCodecDeviations: [Provider: [String: String]] = [
        .plex: ["dca": "dts"],
    ]

    /// Every codec name the domain uses for these titles.
    static let canonicalCodecs: Set<String> = ["hevc", "h264", "eac3", "ac3", "truehd", "dts", "aac", "pgs", "srt"]

    // MARK: Loading

    private static let plexServerID = "c0ffeec0ffeec0ffeec0ffeec0ffeec0"
    private static let jellyfinServerID = "feedfacefeedfacefeedfacefeedface"

    private struct PlexEnvelope: Decodable {
        struct Container: Decodable {
            let Metadata: [PlexMediaDetailsDTO]
        }
        let MediaContainer: Container
    }

    private final class BundleToken {}

    private static func plexFixture(_ name: String) throws -> Data {
        let file = "plex-contract-\(name)"
        if let url = Bundle(for: BundleToken.self).url(forResource: file, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PlexContract", isDirectory: true)
        return try Data(contentsOf: directory.appendingPathComponent("\(file).json"))
    }

    static func details(_ provider: Provider, _ title: Title) throws -> MediaDetails {
        switch provider {
        case .plex:
            let envelope = try JSONDecoder().decode(PlexEnvelope.self, from: plexFixture(title.name))
            let dto = try #require(envelope.MediaContainer.Metadata.first)
            return PlexItemMapper.map(dto, serverID: plexServerID)
        case .jellyfin:
            let dto = try JellyfinFixtures.decode(JellyfinItemDTO.self, "item-\(title.name)")
            return JellyfinItemMapper.mapDetails(dto, serverID: jellyfinServerID)
        }
    }

    private static func streams(_ details: MediaDetails) throws -> [MediaStream] {
        try #require(details.media.first?.parts.first?.streams)
    }

    private static func canonical(_ codec: String?, _ provider: Provider) -> String? {
        guard let codec else { return nil }
        return knownCodecDeviations[provider]?[codec] ?? codec
    }

    // MARK: Per provider

    /// What every provider must hand the rest of the app, checked on each
    /// provider's mapping of each title on its own.
    @Test("domain shape", arguments: Provider.allCases, Title.all)
    func domainShape(_ provider: Provider, _ title: Title) throws {
        let details = try Self.details(provider, title)
        #expect(details.type == title.kind)
        #expect(details.serverID != nil)
        #expect(!details.itemID.isEmpty)
        #expect((details.duration ?? 0) > 0)
        #expect(details.media.count == 1)
        #expect(details.media.first?.parts.count == 1)

        let streams = try Self.streams(details)
        let ids = streams.map(\.id)
        #expect(Set(ids).count == ids.count, "stream ids are unique within a part")
        #expect(streams.filter { $0.kind == .video }.count == 1)
        #expect(streams.allSatisfy { $0.kind != .subtitle || $0.key == nil }, "these files have no sidecars")
        // Embedded order is the container's order: within each kind the
        // positions an engine sees follow the file.
        for kind in [StreamKind.video, .audio, .subtitle] {
            let numeric = streams.filter { $0.kind == kind }.compactMap { Int($0.id) }
            if provider == .jellyfin { #expect(numeric == numeric.sorted()) }
        }

        #expect(details.externalIDs.tmdb != nil)
        #expect(details.externalIDs.imdb != nil)
        #expect(details.contentKey.isStrong)
        #expect(!details.contentAliases.isEmpty)
    }

    /// Codecs are in the domain vocabulary. A provider with a known deviation
    /// records it as a known issue for the titles it affects.
    @Test("canonical codec names", arguments: Provider.allCases, Title.all)
    func canonicalCodecs(_ provider: Provider, _ title: Title) throws {
        let codecs = try Self.streams(Self.details(provider, title)).compactMap(\.codec)
        let deviating = codecs.filter { Self.knownCodecDeviations[provider]?[$0] != nil }
        if deviating.isEmpty {
            #expect(codecs.allSatisfy(Self.canonicalCodecs.contains), "\(codecs)")
        } else {
            withKnownIssue("\(provider) mapper spells \(Set(deviating).sorted()) (04 §4.2 says dts)") {
                #expect(codecs.allSatisfy(Self.canonicalCodecs.contains), "\(codecs)")
            }
        }
    }

    // MARK: Across providers

    @Test("same stream kinds and canonical codecs, in container order", arguments: Title.all)
    func sameStreams(_ title: Title) throws {
        let plex = try Self.streams(Self.details(.plex, title))
        let jellyfin = try Self.streams(Self.details(.jellyfin, title))

        #expect(plex.map(\.kind) == jellyfin.map(\.kind))
        for kind in [StreamKind.video, .audio, .subtitle] {
            let plexCodecs = plex.filter { $0.kind == kind }.map { Self.canonical($0.codec, .plex) }
            let jellyfinCodecs = jellyfin.filter { $0.kind == kind }.map { Self.canonical($0.codec, .jellyfin) }
            #expect(plexCodecs == jellyfinCodecs, "\(kind)")
        }
    }

    @Test("same track facts the pickers and the resolver read", arguments: Title.all)
    func sameTrackFacts(_ title: Title) throws {
        let plex = try Self.streams(Self.details(.plex, title))
        let jellyfin = try Self.streams(Self.details(.jellyfin, title))

        func audio(_ streams: [MediaStream]) -> [String] {
            streams.filter { $0.kind == .audio }.map {
                "\($0.languageCode ?? "-") \($0.channels ?? 0)ch atmos=\(StreamResolver.isDolbyAtmos($0))"
            }
        }
        #expect(audio(plex) == audio(jellyfin))

        func subtitleFlags(_ streams: [MediaStream]) -> [String] {
            streams.filter { $0.kind == .subtitle }.map {
                "forced=\($0.isForced == true) sdh=\($0.isHearingImpaired == true)"
            }
        }
        #expect(subtitleFlags(plex) == subtitleFlags(jellyfin))

        let plexVideo = try #require(plex.first { $0.kind == .video })
        let jellyfinVideo = try #require(jellyfin.first { $0.kind == .video })
        #expect(plexVideo.width == jellyfinVideo.width)
        #expect(plexVideo.height == jellyfinVideo.height)
        #expect(plexVideo.bitDepth == jellyfinVideo.bitDepth)
        #expect(plexVideo.profile == jellyfinVideo.profile)
        #expect(plexVideo.dolbyVision?.profile == jellyfinVideo.dolbyVision?.profile)
        #expect(plexVideo.dolbyVision?.blCompatID == jellyfinVideo.dolbyVision?.blCompatID)
        #expect(StreamResolver.hdrTransfer(of: plexVideo) == StreamResolver.hdrTransfer(of: jellyfinVideo))

        let plexVersion = try #require(try Self.details(.plex, title).media.first)
        let jellyfinVersion = try #require(try Self.details(.jellyfin, title).media.first)
        #expect(plexVersion.container == jellyfinVersion.container)
        #expect(plexVersion.videoResolution == jellyfinVersion.videoResolution)
        #expect(abs((plexVersion.bitrate ?? 0) - (jellyfinVersion.bitrate ?? 0)) <= 1)
    }

    @Test("duration within one second", arguments: Title.all)
    func sameDuration(_ title: Title) throws {
        let plex = try Self.details(.plex, title)
        let jellyfin = try Self.details(.jellyfin, title)
        let plexDuration = try #require(plex.duration)
        let jellyfinDuration = try #require(jellyfin.duration)
        #expect(abs(plexDuration - jellyfinDuration) <= 1000)
        let plexMedia = try #require(plex.media.first?.duration)
        let jellyfinMedia = try #require(jellyfin.media.first?.duration)
        #expect(abs(plexMedia - jellyfinMedia) <= 1000)
    }

    /// Per namespace where both servers have one (Plex also lists tvdb for
    /// films, Jellyfin does not), and the Jellyfin copy's primary key is one
    /// of the Plex copy's aliases, which is what lets the merge layer re-key
    /// it onto the Plex copy (04 §6.2).
    @Test("same external ids", arguments: Title.all)
    func sameExternalIDs(_ title: Title) throws {
        let plex = try Self.details(.plex, title)
        let jellyfin = try Self.details(.jellyfin, title)
        var compared = 0
        for namespace in ContentKey.externalProviders {
            guard let plexValue = plex.externalIDs.first(namespace),
                  let jellyfinValue = jellyfin.externalIDs.first(namespace) else { continue }
            #expect(plexValue == jellyfinValue, "\(namespace)")
            compared += 1
        }
        #expect(compared >= 2)
        #expect(plex.contentAliases.contains(jellyfin.contentKey))
    }

    @Test("same numbering and air date", arguments: Title.all)
    func sameNumbering(_ title: Title) throws {
        let plex = try Self.details(.plex, title)
        let jellyfin = try Self.details(.jellyfin, title)
        #expect(plex.type == jellyfin.type)
        #expect(plex.index == jellyfin.index)
        #expect(plex.parentIndex == jellyfin.parentIndex)
        #expect(plex.year == jellyfin.year)
        #expect(plex.originallyAvailableAt == jellyfin.originallyAvailableAt)
        #expect(plex.title == jellyfin.title)
        if title.kind == .episode {
            #expect(jellyfin.grandparentTitle != nil)
            #expect(jellyfin.parentID != nil && jellyfin.grandparentID != nil)
        }
    }
}
