import Foundation

struct LibraryPersonalizedShelf: Identifiable, Sendable, Hashable {
    let genre: LibraryGenreOption
    let title: String
    let items: [PlexItem]

    var id: String { genre.id }
}
