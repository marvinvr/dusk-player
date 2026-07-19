import SwiftUI

/// The paged grid of a single collection's items — the "Show all" target of
/// a video library's per-channel rows. Delegates to `LibraryItemsView` with
/// collection scoping, so paging, the sort/genre menus, and the 16:9 video
/// grid layout are all shared with the library browse screen.
struct LibraryCollectionItemsView: View {
    @Environment(PlexService.self) private var plexService

    let library: PlexLibrary
    let collection: PlexLibraryCollection

    var body: some View {
        LibraryItemsView(
            library: library,
            plexService: plexService,
            collection: collection
        )
    }
}
