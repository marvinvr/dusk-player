import Foundation

/// One entry of a title's `Rating` array: a score from one source.
/// `image` names the source (`imdb://image.rating`,
/// `rottentomatoes://image.rating.ripe`, `themoviedb://image.rating`), `type`
/// is `critic` or `audience`, `value` is on Plex's 0–10 scale.
struct PlexRating: Decodable, Hashable, Sendable {
    /// A source's official mark, in `Assets.xcassets/RatingLogos`.
    enum Logo: String, Sendable {
        case imdb = "RatingIMDb"
        case tomatometerFresh = "RatingRTFresh"
        case tomatometerRotten = "RatingRTRotten"
        case popcornmeterHot = "RatingRTUpright"
        case popcornmeterStale = "RatingRTSpilled"
        case tmdb = "RatingTMDB"

        /// Height relative to the line's logo height, so the marks read as one
        /// size: the IMDb wordmark is solid edge to edge, the icons are not.
        var relativeHeight: Double {
            self == .imdb ? 0.8 : 1
        }
    }

    let image: String?
    let value: Double
    let type: String?

    init(image: String?, value: Double, type: String?) {
        self.image = image
        self.value = value
        self.type = type
    }

    /// How a detail page shows it: a source name (spoken with the logo, shown
    /// as text when there is no logo), the value in that source's own scale,
    /// and the source's logo. Nil for a source Dusk cannot name.
    var display: (source: String, value: String, logo: Logo?)? {
        guard let image, let scheme = image.split(separator: ":").first?.lowercased() else { return nil }
        let percent = Int((value * 10).rounded())
        switch scheme {
        case "imdb":
            return ("IMDb", String(format: "%.1f", value), .imdb)
        case "rottentomatoes":
            // ripe/rotten are the critics' Tomatometer; upright/spilled the
            // audience's Popcornmeter. The icon follows the score Dusk shows,
            // not Plex's image: Rotten Tomatoes allows the fresh and hot icons
            // only at 60% or higher, the rotten and stale ones at 59% or lower.
            let isFresh = percent >= 60
            return type == "audience" || image.contains("upright") || image.contains("spilled")
                ? ("Rotten Tomatoes Audience", "\(percent)%", isFresh ? .popcornmeterHot : .popcornmeterStale)
                : ("Rotten Tomatoes", "\(percent)%", isFresh ? .tomatometerFresh : .tomatometerRotten)
        case "themoviedb":
            return ("TMDB", "\(percent)%", .tmdb)
        case "thetvdb":
            return ("TVDB", String(format: "%.1f", value), nil)
        default:
            return nil
        }
    }

    /// The sources to show for a title: Plex's `Rating` array when the server
    /// sends one, else the two scalar ratings with their images.
    static func sources(for details: PlexMediaDetails) -> [PlexRating] {
        let all = details.ratings.isEmpty
            ? [
                details.rating.map { PlexRating(image: details.ratingImage, value: $0, type: "critic") },
                details.audienceRating.map { PlexRating(image: details.audienceRatingImage, value: $0, type: "audience") },
            ].compactMap { $0 }
            : details.ratings
        var seen = Set<String>()
        return all.filter { rating in
            guard let source = rating.display?.source else { return false }
            return seen.insert(source).inserted
        }
    }
}

/// A title's age rating as a detail page shows it.
enum PlexContentRating {
    /// Plex prefixes certifications outside the US with a lowercase country
    /// code (`de/12`, `gb/15`); people only need the rating. US ratings and
    /// values such as `TV-MA` or `N/A` pass through. Nil when there is none.
    static func display(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let slash = raw.firstIndex(of: "/") else { return raw }
        let prefix = raw[..<slash]
        let rating = raw[raw.index(after: slash)...]
        let isCountryCode = (2...3).contains(prefix.count)
            && prefix.allSatisfy { $0.isASCII && $0.isLowercase }
        return isCountryCode && !rating.isEmpty ? String(rating) : raw
    }
}
