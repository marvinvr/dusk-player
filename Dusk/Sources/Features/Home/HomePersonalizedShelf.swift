import Foundation

struct HomePersonalizedShelf: Identifiable, Sendable, Hashable {
    let libraryType: PlexLibraryType
    let genre: LibraryGenreOption
    let title: String
    let items: [PlexItem]
    let showAllLibrary: PlexLibrary?

    var id: String { "\(libraryType.rawValue):\(genre.id)" }
}
