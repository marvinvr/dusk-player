import Foundation

extension MediaService {
    /// The pre-roll videos the server wants played before `itemID`, in
    /// order. Empty when the server has none configured (see
    /// `PlaybackProviding.prerolls(before:)`).
    func cinemaPrerolls(forMovieRatingKey itemID: String, serverID: String?) async throws -> [MediaDetails] {
        try await playback(for: serverID).prerolls(before: itemID)
    }

}
