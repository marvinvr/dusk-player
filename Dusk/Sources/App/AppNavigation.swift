import SwiftUI

enum AppNavigationRoute: Hashable {
    case library(PlexLibrary)
    case libraryGenre(library: PlexLibrary, genre: LibraryGenreOption)
    case libraryRecommendations(PlexLibrary)
    case hub(PlexHub)
    case media(type: PlexMediaType, ratingKey: String)
    case person(PlexPersonReference)

    static func destination(for item: PlexItem) -> Self {
        if let person = PlexPersonReference(item: item) {
            return .person(person)
        }

        return .media(type: item.type, ratingKey: item.ratingKey)
    }
}

struct AppNavigationDestinationView: View {
    @Environment(PlexService.self) private var plexService

    let route: AppNavigationRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .library(let library):
            LibraryItemsView(library: library, plexService: plexService)
        case .libraryGenre(let library, let genre):
            LibraryItemsView(
                library: library,
                plexService: plexService,
                initialGenre: genre,
                preferLocalGenreFiltering: true
            )
        case .libraryRecommendations(let library):
            LibraryRecommendationsView(
                library: library,
                plexService: plexService,
                navigationTitle: library.title
            )
        case .hub(let hub):
            HomeHubItemsView(hub: hub, plexService: plexService)
        case let .media(type, ratingKey):
            MediaDetailDestinationView(
                type: type,
                ratingKey: ratingKey,
                plexService: plexService
            )
        case .person(let person):
            ActorDetailView(person: person, plexService: plexService)
        }
    }
}

extension View {
    func duskAppNavigationDestinations() -> some View {
        navigationDestination(for: AppNavigationRoute.self) { route in
            AppNavigationDestinationView(route: route)
        }
    }
}
