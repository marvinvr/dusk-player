import Foundation
import Testing
@testable import Dusk

/// #62: a season Plex lacks on a partly available show read "Partial", so its
/// page offered no Request button and, on tvOS, nothing to focus.
@Suite("Seerr season request state")
struct SeerrRequestStateTests {
    /// Seerr's scan lists every season; one with no episodes in Plex is
    /// `unknown` (1) while the show is `partiallyAvailable` (4).
    private func mediaInfo(_ json: String) throws -> SeerrMediaInfo {
        try JSONDecoder().decode(SeerrMediaInfo.self, from: Data(json.utf8))
    }

    @Test func missingSeasonOfPartlyAvailableShowIsRequestable() throws {
        let info = try mediaInfo("""
        {"status": 4, "seasons": [
            {"seasonNumber": 1, "status": 5},
            {"seasonNumber": 2, "status": 1}
        ]}
        """)
        let state = SeerrRequestState.resolve(mediaInfo: info, currentUserID: 1, seasonNumber: 2)
        #expect(state == .requestable)
        #expect(state.canRequest)
    }

    @Test func seasonAbsentFromSeasonListIsRequestable() throws {
        let info = try mediaInfo("""
        {"status": 4, "seasons": [{"seasonNumber": 1, "status": 5}]}
        """)
        #expect(SeerrRequestState.resolve(mediaInfo: info, currentUserID: 1, seasonNumber: 3) == .requestable)
    }

    @Test func seasonsKeepTheirOwnStatus() throws {
        let info = try mediaInfo("""
        {"status": 4, "seasons": [
            {"seasonNumber": 1, "status": 5},
            {"seasonNumber": 2, "status": 4}
        ]}
        """)
        #expect(SeerrRequestState.resolve(mediaInfo: info, currentUserID: 1, seasonNumber: 1) == .available)
        #expect(SeerrRequestState.resolve(mediaInfo: info, currentUserID: 1, seasonNumber: 2) == .partiallyAvailable)
    }

    @Test func requestedMissingSeasonShowsItsRequest() throws {
        let info = try mediaInfo("""
        {"status": 4,
         "seasons": [{"seasonNumber": 1, "status": 5}, {"seasonNumber": 2, "status": 1}],
         "requests": [{"id": 9, "status": 1, "requestedBy": {"id": 1, "permissions": 0},
                       "seasons": [{"seasonNumber": 2, "status": 1}]}]}
        """)
        #expect(SeerrRequestState.resolve(mediaInfo: info, currentUserID: 1, seasonNumber: 2) == .pending)
    }

    @Test func showLevelStateIsUnchanged() throws {
        let info = try mediaInfo("""
        {"status": 4, "seasons": [{"seasonNumber": 1, "status": 5}]}
        """)
        #expect(SeerrRequestState.resolve(mediaInfo: info, currentUserID: 1) == .partiallyAvailable)
    }
}
