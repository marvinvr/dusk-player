import Foundation
import Testing
@testable import Dusk

/// Whether a refetch after a subtitle download shows Plex has applied it
/// (the PUT returns before Plex refreshed the item).
@Suite("Subtitle download application")
struct SubtitleDownloadApplicationTests {
    /// Normalized the way the coordinator normalizes a download result's `ger`.
    private static let german = PlayerViewModel.normalizedLanguageCode("ger")

    private func streams(_ json: String) throws -> [PlexStream] {
        try JSONDecoder().decode([PlexStream].self, from: Data("[\(json)]".utf8))
    }

    private let before = #"""
        {"id":10,"streamType":2,"languageCode":"eng","codec":"ac3"},
        {"id":20,"streamType":3,"languageCode":"eng","codec":"srt"},
        {"id":30,"streamType":3,"languageCode":"ger","codec":"srt","key":"/library/streams/30","displayTitle":"Deutsch (SRT)"}
        """#

    @Test func unchangedRefetchIsNotApplied() throws {
        let old = try streams(before)
        #expect(!SubtitleDownloadApplication.hasNewSidecar(before: old, after: old, language: Self.german))
    }

    @Test func newSidecarIdInLanguageIsApplied() throws {
        let after = try streams(before + #", {"id":31,"streamType":3,"languageCode":"ger","codec":"srt","key":"/library/streams/31"}"#)
        #expect(SubtitleDownloadApplication.hasNewSidecar(before: try streams(before), after: after, language: Self.german))
    }

    @Test func inPlaceReplacementWithChangedTitleIsApplied() throws {
        let after = try streams(before.replacingOccurrences(of: "Deutsch (SRT)", with: "Deutsch (OpenSubtitles)"))
        #expect(SubtitleDownloadApplication.hasNewSidecar(before: try streams(before), after: after, language: Self.german))
    }

    @Test func sidecarInAnotherLanguageDoesNotCount() throws {
        let after = try streams(before + #", {"id":40,"streamType":3,"languageCode":"fre","codec":"srt","key":"/library/streams/40"}"#)
        #expect(!SubtitleDownloadApplication.hasNewSidecar(before: try streams(before), after: after, language: Self.german))
        #expect(SubtitleDownloadApplication.hasNewSidecar(before: try streams(before), after: after, language: nil))
    }

    @Test func droppedSidecarAloneIsNotApplied() throws {
        // Plex can drop the old stream a moment before the new one appears.
        let after = try streams(#"""
            {"id":10,"streamType":2,"languageCode":"eng","codec":"ac3"},
            {"id":20,"streamType":3,"languageCode":"eng","codec":"srt"}
            """#)
        #expect(!SubtitleDownloadApplication.hasNewSidecar(before: try streams(before), after: after, language: Self.german))
    }

    @Test func embeddedStreamsAreIgnored() throws {
        let after = try streams(before + #", {"id":50,"streamType":3,"languageCode":"ger","codec":"pgs"}"#)
        #expect(!SubtitleDownloadApplication.hasNewSidecar(before: try streams(before), after: after, language: Self.german))
    }

    @Test func digestTellsFilesApart() {
        let a = SubtitleDownloadApplication.digest(of: Data("1\n00:00:01,000 --> 00:00:02,000\nHallo\n".utf8))
        let b = SubtitleDownloadApplication.digest(of: Data("1\n00:00:01,000 --> 00:00:02,000\nServus\n".utf8))
        #expect(a != b)
        #expect(a == SubtitleDownloadApplication.digest(of: Data("1\n00:00:01,000 --> 00:00:02,000\nHallo\n".utf8)))
    }

    @Test func pollIsBounded() {
        let total = SubtitleDownloadApplication.pollDelays.reduce(Duration.zero, +)
        #expect(SubtitleDownloadApplication.pollDelays.first == .zero)
        #expect(total <= .seconds(8))
    }
}
