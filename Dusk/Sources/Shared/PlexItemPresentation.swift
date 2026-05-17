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
        if type == .episode {
            return MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index) ?? title
        }
        return year.map(String.init)
    }

    var standardPosterSubtitle: String? {
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
