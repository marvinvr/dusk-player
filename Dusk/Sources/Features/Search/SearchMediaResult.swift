import Foundation

enum SearchMediaResult: Identifiable {
    case plex(PlexItem)
    case seerr(SeerrSearchMedia)

    var id: String {
        switch self {
        case .plex(let item): "plex:\(item.ratingKey)"
        case .seerr(let item): "seerr:\(item.mediaType):\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .plex(let item): item.title
        case .seerr(let item): item.displayTitle
        }
    }

    var subtitle: String? {
        switch self {
        case .plex(let item):
            item.standardPosterSubtitle
        case .seerr(let item):
            item.year.map(String.init)
        }
    }

    var route: AppNavigationRoute {
        switch self {
        case .plex(let item):
            AppNavigationRoute.destination(for: item)
        case .seerr(let item):
            .seerrMedia(type: item.supportedMediaType ?? .movie, id: item.id)
        }
    }

    var progress: Double? {
        guard case .plex(let item) = self else { return nil }
        return item.posterProgress
    }

    var isClip: Bool {
        guard case .plex(let item) = self else { return false }
        return item.isClip
    }

    @MainActor
    func imageURL(
        plexService: PlexService,
        seerrService: SeerrService,
        width: Int,
        height: Int
    ) -> URL? {
        switch self {
        case .plex(let item):
            plexService.imageURL(
                for: item.preferredPosterPath,
                width: width,
                height: height
            )
        case .seerr(let item):
            seerrService.posterURL(path: item.posterPath, width: width)
        }
    }

    @MainActor
    func availabilityBadge(using service: SeerrService) -> String? {
        guard case .seerr(let item) = self else { return nil }
        return service.requestState(mediaInfo: item.mediaInfo).badgeTitle
    }
}

struct SearchMediaResultGroup: Identifiable {
    let id: String
    let title: String
    let type: String?
    var items: [SearchMediaResult]

    var isAllClips: Bool {
        !items.isEmpty && items.allSatisfy(\.isClip)
    }
}
