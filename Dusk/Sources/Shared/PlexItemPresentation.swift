import Foundation

extension PlexItem {
    var posterProgress: Double? {
        MediaTextFormatter.progress(durationMs: duration, offsetMs: viewOffset)
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
        return year.map(String.init)
    }

    /// Clip cards show a compact duration instead of a year.
    var clipPosterSubtitle: String? {
        MediaTextFormatter.compactDuration(milliseconds: duration) ?? year.map(String.init)
    }

    var standardPosterSubtitle: String? {
        if isClip {
            return clipPosterSubtitle
        }
        switch type {
        case .movie:
            return year.map(String.init)
        case .show:
            if let childCount {
                return MediaTextFormatter.seasonCount(childCount)?.lowercased()
            }
            return year.map(String.init)
        case .episode:
            return MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index) ?? grandparentTitle
        default:
            return year.map(String.init)
        }
    }

    var filmographyPosterSubtitle: String? {
        switch type {
        case .movie:
            return year.map(String.init)
        case .show:
            let parts = [
                year.map(String.init),
                childCount.flatMap { MediaTextFormatter.seasonCount($0) },
            ]
            .compactMap { $0 }

            return parts.joined(separator: " · ").nilIfEmpty
        default:
            return nil
        }
    }

    @MainActor
    func posterImageURL(plexService: PlexService, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: preferredPosterPath, width: width, height: height)
    }

    @MainActor
    func landscapeImageURL(plexService: PlexService, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: preferredLandscapePath, width: width, height: height)
    }
}

/// Shared "video row" decision for hub-shaped rows (Home hubs, search result
/// groups, hub item grids): a non-empty row consisting entirely of clips
/// renders as a 16:9 carousel/grid; anything mixed or non-clip keeps the 2:3
/// poster layout.
extension Collection where Element == PlexItem {
    var isAllClips: Bool {
        !isEmpty && allSatisfy(\.isClip)
    }
}
