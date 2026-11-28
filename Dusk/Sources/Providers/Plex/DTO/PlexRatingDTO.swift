import Foundation

/// One entry of a Plex title's `Rating` array. `image` names the source
/// (`imdb://image.rating`, `rottentomatoes://image.rating.ripe`, …), `type` is
/// `critic` or `audience`, `value` is on Plex's 0–10 scale. A missing `value`
/// fails the decode.
struct PlexRatingDTO: Decodable, Sendable {
    let image: String?
    let value: Double
    let type: String?
}
