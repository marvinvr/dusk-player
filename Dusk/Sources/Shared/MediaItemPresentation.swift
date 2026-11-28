import Foundation

/// Large series heroes use parent artwork, never an episode's small still.
enum SeriesBackdropArtwork {
    static func path(
        season: MediaDetails?,
        show: MediaDetails?,
        episode: MediaDetails? = nil
    ) -> String? {
        season?.art?.nilIfEmpty
            ?? show?.art?.nilIfEmpty
            ?? show?.thumb?.nilIfEmpty
            ?? season?.parentThumb?.nilIfEmpty
            ?? episode?.grandparentThumb?.nilIfEmpty
            ?? season?.thumb?.nilIfEmpty
            ?? episode?.parentThumb?.nilIfEmpty
    }
}

extension MediaItem {
    var posterProgress: Double? {
        MediaTextFormatter.progress(durationMs: duration, offsetMs: resumeOffsetMs)
    }

    /// The quiet checkmark under a poster card: a played movie, episode or
    /// clip, or a show/season with every episode watched. Same rule as the
    /// season cards, so a row of mixed items marks them all alike.
    var posterIsWatched: Bool {
        switch type {
        case .movie, .episode, .clip, .show, .season:
            return isWatched
        default:
            return false
        }
    }

    /// A played movie, episode or clip carries `WatchedBadge` on its artwork
    /// in place of the subtitle checkmark. Shows and seasons keep the quiet
    /// checkmark (and `UnwatchedCountBadge`) under the card.
    var posterShowsWatchedBadge: Bool {
        switch type {
        case .movie, .episode, .clip:
            return isWatched
        default:
            return false
        }
    }

    /// The title under a poster. A season or episode on its own in a row
    /// (Recently Added, mostly) is known by its show — "Season 6" alone says
    /// nothing — so it takes the show's title and leaves the numbering to the
    /// subtitle (`standardPosterSubtitle`).
    var posterCardTitle: String {
        switch type {
        case .season:
            return parentTitle?.nilIfEmpty ?? title
        case .episode:
            return grandparentTitle?.nilIfEmpty ?? title
        default:
            return title
        }
    }

    var continueWatchingDisplayTitle: String {
        if type == .episode, let show = grandparentTitle {
            return show
        }
        return title
    }

    var continueWatchingDisplaySubtitle: String? {
        if isClip {
            return clipPosterSubtitle
        }
        if type == .episode {
            return MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index) ?? title
        }
        return appendingEdition(to: year.map(String.init))
    }

    /// Clip cards show their full upload date plus compact duration. Videos
    /// from the last week also include relative date context.
    var clipPosterSubtitle: String? {
        MediaTextFormatter.clipCardSubtitle(
            originallyAvailableAt: originallyAvailableAt,
            duration: duration,
            fallbackYear: year
        )
    }

    var standardPosterSubtitle: String? {
        if isClip {
            return clipPosterSubtitle
        }
        switch type {
        case .movie:
            return appendingEdition(to: year.map(String.init))
        case .show:
            if let childCount {
                return appendingEdition(to: MediaTextFormatter.seasonCount(childCount)?.lowercased())
            }
            return appendingEdition(to: year.map(String.init))
        case .season:
            return title.nilIfEmpty ?? MediaTextFormatter.seasonEpisodeLabel(season: index, episode: nil)
        case .episode:
            return MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index) ?? grandparentTitle
        case .collection:
            return collectionCountLabel
        default:
            return year.map(String.init)
        }
    }

    /// `12 movies`, `3 shows`, `1 item`: a collection's size in the words of
    /// what it holds.
    var collectionCountLabel: String? {
        guard type == .collection, let childCount else { return nil }
        return Self.collectionCountLabel(childCount, subtype: subtype)
    }

    static func collectionCountLabel(_ count: Int, subtype: String?) -> String {
        let noun: (String, String) = switch subtype {
        case "movie": ("movie", "movies")
        case "show": ("show", "shows")
        case "episode": ("episode", "episodes")
        case "clip": ("video", "videos")
        default: ("item", "items")
        }
        return "\(count) \(count == 1 ? noun.0 : noun.1)"
    }

    /// Home's poster rows show a year under movies and shows, but a season or
    /// episode needs its numbering there because its title is the show's
    /// ("S6 · E3": the long form does not fit under a poster).
    var hubPosterSubtitle: String? {
        switch type {
        case .season:
            return standardPosterSubtitle
        case .episode:
            return MediaTextFormatter.compactSeasonEpisodeLabel(season: parentIndex, episode: index)
                ?? standardPosterSubtitle
        case .collection:
            return collectionCountLabel
        default:
            return appendingEdition(to: year.map(String.init))
        }
    }

    var filmographyPosterSubtitle: String? {
        switch type {
        case .movie:
            return appendingEdition(to: year.map(String.init))
        case .show:
            let parts = [
                year.map(String.init),
                childCount.flatMap { MediaTextFormatter.seasonCount($0) },
                editionTitle,
            ]
            .compactMap { $0 }

            return parts.joined(separator: " · ").nilIfEmpty
        default:
            return nil
        }
    }

    /// `1982 · Director's Cut`: a movie or show's edition rides along in its
    /// subtitle, quietly, so two editions with the same poster can be told
    /// apart. Plex only sends an edition when the server holds several.
    func appendingEdition(to base: String?) -> String? {
        MediaTextFormatter.joinedWithEdition(base, edition: editionTitle)
    }

    /// Artwork always comes from the item's own server: a merged row mixes
    /// items from several servers, and the paths are only valid on theirs.
    @MainActor
    func posterImageURL(media: MediaService, width: Int, height: Int) -> URL? {
        media.imageURL(for: preferredPoster, size: ImageSize(width: width, height: height))
    }

    @MainActor
    func fallbackPosterImageURL(media: MediaService, width: Int, height: Int) -> URL? {
        media.imageURL(for: fallbackPoster, size: ImageSize(width: width, height: height))
    }

    @MainActor
    func landscapeImageURL(media: MediaService, width: Int, height: Int) -> URL? {
        media.imageURL(for: preferredLandscape, size: ImageSize(width: width, height: height))
    }
}

/// Shared "video row" decision for hub-shaped rows (Home hubs, search result
/// groups, hub item grids): a non-empty row consisting entirely of clips
/// renders as a 16:9 carousel/grid; anything mixed or non-clip keeps the 2:3
/// poster layout.
extension Collection where Element == MediaItem {
    var isAllClips: Bool {
        !isEmpty && allSatisfy(\.isClip)
    }
}
