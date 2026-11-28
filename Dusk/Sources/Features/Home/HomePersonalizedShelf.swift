import Foundation

struct HomePersonalizedShelf: Identifiable, Sendable, Hashable {
    let libraryType: LibraryKind
    let genre: LibraryGenreOption
    let title: String
    let items: [MediaItem]
    let showAllLibrary: Library?

    var id: String { "\(libraryType.rawValue):\(genre.id)" }
}
