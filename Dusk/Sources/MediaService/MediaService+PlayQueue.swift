import Foundation

extension MediaService {
    /// The pre-roll videos the server wants played before `itemID`, in
    /// order. Empty when the server has none configured (see
    /// `PlaybackProviding.prerolls(before:)`).
    func cinemaPrerolls(forMovieRatingKey itemID: String, serverID: String?) async throws -> [MediaDetails] {
        try await playback(for: serverID).prerolls(before: itemID)
    }

    /// Everything the queue puts in front of the movie. Only clips count: a
    /// queue that somehow led with anything else is not a pre-roll queue.
    static func prerollItems(in queue: [MediaDetails], featureRatingKey: String) -> [MediaDetails] {
        PlexPlayback.prerollItems(in: queue, featureRatingKey: featureRatingKey)
    }
}
