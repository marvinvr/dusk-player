#if os(macOS)
import SwiftUI

/// A library type's sidebar destination (Movies, TV Shows, Videos) on the Mac:
/// one place with a segmented control in the toolbar, Recommended | Library |
/// Collections, like the TV app's mode switch, instead of iOS's three pushed
/// screens that were all titled "Movies". Collections only shows when the
/// library has any. With several libraries of the type, Recommended merges
/// them and Library/Collections get a library pop-up next to the switch.
///
/// The modes are this view's state, so a detail page pushed from any of them
/// comes back to the same mode.
struct MacLibraryBrowser: View {
    @Environment(PlexService.self) private var plexService

    let libraryType: PlexLibraryType
    let libraries: [PlexLibrary]
    let viewModel: LibrariesViewModel
    @Binding var path: NavigationPath

    enum Mode: String, Hashable {
        case recommended
        case library
        case collections
    }

    @State private var mode: Mode = Self.initialMode
    @State private var selectedLibraryID: String?
    /// Library id → whether it has collections to browse (and has them on).
    @State private var collectionsAvailable: [String: Bool] = [:]

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        Text("Recommended").tag(Mode.recommended)
                        Text("Library").tag(Mode.library)
                        if hasCollections {
                            Text("Collections").tag(Mode.collections)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                if libraries.count > 1, mode != .recommended {
                    ToolbarItem(placement: .navigation) {
                        Picker("Library", selection: libraryBinding) {
                            ForEach(libraries) { library in
                                Text(viewModel.displayTitle(for: library)).tag(library.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .help("Library")
                    }
                }
            }
            .task(id: selectedLibrary.id) {
                await loadCollectionsAvailability(for: selectedLibrary)
            }
            .onChange(of: hasCollections) { _, has in
                if !has, mode == .collections { mode = .library }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .recommended:
            LibraryRecommendationsView(
                libraries: libraries,
                plexService: plexService,
                navigationTitle: libraryType.tabTitle,
                browseTargets: libraries.map {
                    LibraryBrowseTarget(library: $0, title: viewModel.displayTitle(for: $0))
                },
                libraryListDestination: nil,
                push: { path.append($0) }
            )
            .id(libraries.map(\.id).joined(separator: "|"))
        case .library:
            LibraryItemsView(library: selectedLibrary, plexService: plexService)
                .id(selectedLibrary.id)
        case .collections:
            LibraryCollectionsView(library: selectedLibrary, plexService: plexService)
                .id(selectedLibrary.id)
        }
    }

    private var selectedLibrary: PlexLibrary {
        libraries.first { $0.id == selectedLibraryID } ?? libraries[0]
    }

    private var libraryBinding: Binding<String> {
        Binding(
            get: { selectedLibrary.id },
            set: { selectedLibraryID = $0 }
        )
    }

    private var hasCollections: Bool {
        collectionsAvailable[selectedLibrary.id] == true
    }

    /// Same check as the library grid's Collections chip: the section's
    /// Collections setting isn't off and it has at least one.
    private func loadCollectionsAvailability(for library: PlexLibrary) async {
        guard collectionsAvailable[library.id] == nil else { return }
        guard library.libraryType == .movie || library.libraryType == .show else {
            collectionsAvailable[library.id] = false
            return
        }
        async let mode = plexService.collectionMode(sectionId: library.key, serverID: library.serverID)
        async let firstPage = try? plexService.getCollections(
            sectionId: library.key,
            size: 1,
            serverID: library.serverID
        )
        let resolvedMode = await mode
        let page = await firstPage
        guard !Task.isCancelled else { return }
        collectionsAvailable[library.id] = resolvedMode != .disabled && page?.items.isEmpty == false
    }

    private static var initialMode: Mode {
        #if DEBUG
        // QA screenshots: `-DuskMacLibraryMode library|collections`.
        if let raw = UserDefaults.standard.string(forKey: "DuskMacLibraryMode"),
           let mode = Mode(rawValue: raw) {
            return mode
        }
        #endif
        return .recommended
    }
}
#endif
