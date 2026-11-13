import Foundation
import Testing
@testable import Dusk

/// AVFoundation lists a synthesized "forced only" option next to every subtitle
/// track. `PlayerViewModel.forcedTwinSource` maps such an option back to the
/// full Plex stream it belongs to instead of letting it consume the next one.
@Suite("Forced subtitle twins")
struct ForcedSubtitleTwinTests {
    private func streams(_ json: String) throws -> [PlexStream] {
        try JSONDecoder().decode([PlexStream].self, from: Data("[\(json)]".utf8))
    }

    private func engineTrack(id: Int, code: String?, forced: Bool, external: Bool = false) -> SubtitleTrack {
        SubtitleTrack(
            id: id,
            displayTitle: "Track \(id)",
            language: nil,
            languageCode: code,
            codec: "mov_text",
            isForced: forced,
            isHearingImpaired: false,
            isExternal: external,
            externalURL: external ? URL(string: "http://example.invalid/sub.srt") : nil
        )
    }

    private let threeLanguages = #"""
        {"id":10,"streamType":3,"codec":"mov_text","language":"English","languageCode":"eng"},
        {"id":11,"streamType":3,"codec":"mov_text","language":"Français","languageCode":"fra"},
        {"id":12,"streamType":3,"codec":"mov_text","language":"Deutsch","languageCode":"deu"}
        """#

    @Test func forcedTwinBorrowsItsOwnLanguagesFullTrack() throws {
        let plex = try streams(threeLanguages)
        let source = PlayerViewModel.forcedTwinSource(
            for: engineTrack(id: 1, code: "en", forced: true),
            in: plex,
            after: [SubtitleTrack(stream: plex[0])]
        )
        #expect(source?.id == 10)
    }

    @Test func fullTracksAreNeverTwins() throws {
        let plex = try streams(threeLanguages)
        #expect(PlayerViewModel.forcedTwinSource(
            for: engineTrack(id: 2, code: "fr", forced: false), in: plex, after: []
        ) == nil)
    }

    @Test func aRealForcedPlexStreamIsMatchedNormally() throws {
        let plex = try streams(#"""
            {"id":10,"streamType":3,"codec":"srt","language":"English","languageCode":"eng"},
            {"id":13,"streamType":3,"codec":"srt","language":"English","languageCode":"eng","forced":true}
            """#)
        #expect(PlayerViewModel.forcedTwinSource(
            for: engineTrack(id: 1, code: "en", forced: true), in: plex, after: []
        ) == nil)
    }

    @Test func externalAndUnknownLanguageTracksAreLeftAlone() throws {
        let plex = try streams(threeLanguages)
        #expect(PlayerViewModel.forcedTwinSource(
            for: engineTrack(id: 1, code: "en", forced: true, external: true), in: plex, after: []
        ) == nil)
        #expect(PlayerViewModel.forcedTwinSource(
            for: engineTrack(id: 1, code: nil, forced: true), in: plex, after: []
        ) == nil)
        #expect(PlayerViewModel.forcedTwinSource(
            for: engineTrack(id: 1, code: "it", forced: true), in: plex, after: []
        ) == nil)
    }

    @Test func withSeveralFullTracksTheTwinFollowsThePrecedingOne() throws {
        let plex = try streams(#"""
            {"id":20,"streamType":3,"codec":"pgs","language":"English","languageCode":"eng"},
            {"id":21,"streamType":3,"codec":"srt","language":"English","languageCode":"eng"}
            """#)
        let source = PlayerViewModel.forcedTwinSource(
            for: engineTrack(id: 3, code: "en", forced: true),
            in: plex,
            after: [SubtitleTrack(stream: plex[0]), SubtitleTrack(stream: plex[1])]
        )
        #expect(source?.id == 21)
    }
}
