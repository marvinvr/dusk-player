import Foundation

struct LibraryPersonalizedShelf: Identifiable, Sendable, Hashable {
    let genre: LibraryGenreOption
    let title: String
    let items: [PlexItem]
    /// The library "Show All" pages. nil once the row has been merged across
    /// several libraries, because there is no single list to open.
    let showAllLibrary: PlexLibrary?

    var id: String { genre.id }
}
